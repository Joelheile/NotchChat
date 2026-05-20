// notchchat-whatsapp-sidecar bridges WhatsApp (via the whatsmeow multidevice
// library) to the boring.notch macOS app. It exposes a tiny localhost-only HTTP
// API: a Server-Sent-Events stream for login/QR/message events plus endpoints
// to send text and fetch downloaded audio.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

// Message is the wire format shared with the Swift client. JSON keys must stay
// in sync with WAMessage in WhatsAppModels.swift.
type Message struct {
	ID               string `json:"id"`
	ChatJID          string `json:"chatJID"`
	SenderJID        string `json:"senderJID"`
	FromMe           bool   `json:"fromMe"`
	Timestamp        int64  `json:"timestamp"`
	Text             string `json:"text"`
	Type             string `json:"type"` // text | audio | image | other
	MediaID          string `json:"mediaID,omitempty"`
	MediaContentType string `json:"mediaContentType,omitempty"`
	Duration         int    `json:"duration"`
	PushName         string `json:"pushName"`
}

// Event is one Server-Sent-Events frame.
type Event struct {
	Type string      `json:"type"`
	Data interface{} `json:"data,omitempty"`
}

type App struct {
	client    *whatsmeow.Client
	container *sqlstore.Container
	dataDir   string
	mediaDir  string
	avatarDir string
	token     string
	port      int
	clientLog waLog.Logger
	dbLog     waLog.Logger

	mu       sync.Mutex
	subs     map[chan []byte]bool
	messages []Message
	lastQR   string          // most recent QR code, replayed to new SSE clients
	contacts map[string]bool // configured chat JIDs; scopes history import
}

// historyWindow bounds how far back history sync is imported.
const historyWindow = 30 * 24 * time.Hour

const maxStoredMessages = 500

func main() {
	port := flag.Int("port", 8765, "localhost port to listen on")
	dataDir := flag.String("data", defaultDataDir(), "directory for the WhatsApp session store")
	token := flag.String("token", "", "shared secret required on every request; empty disables auth (dev only)")
	flag.Parse()

	// 0o700: the session store and message cache contain WhatsApp keys and
	// chat history, so keep them unreadable by other local users.
	if err := os.MkdirAll(*dataDir, 0o700); err != nil {
		log.Fatalf("cannot create data dir: %v", err)
	}
	app := &App{
		dataDir:   *dataDir,
		mediaDir:  filepath.Join(*dataDir, "media"),
		avatarDir: filepath.Join(*dataDir, "avatars"),
		token:     *token,
		port:      *port,
		clientLog: waLog.Stdout("Client", "WARN", true),
		dbLog:     waLog.Stdout("DB", "WARN", true),
		subs:      map[chan []byte]bool{},
		contacts:  map[string]bool{},
	}
	for _, dir := range []string{app.mediaDir, app.avatarDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			log.Fatalf("cannot create dir %s: %v", dir, err)
		}
	}
	if app.token == "" {
		log.Print("WARNING: no --token set, request authentication is DISABLED")
	}
	app.loadMessages()

	if err := app.startWhatsApp(); err != nil {
		log.Fatalf("whatsapp init failed: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/events", app.handleEvents)
	mux.HandleFunc("/status", app.handleStatus)
	mux.HandleFunc("/send", app.handleSend)
	mux.HandleFunc("/sendImage", app.handleSendImage)
	mux.HandleFunc("/media", app.handleMedia)
	mux.HandleFunc("/avatar", app.handleAvatar)
	mux.HandleFunc("/contacts", app.handleContacts)
	mux.HandleFunc("/logout", app.handleLogout)

	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	srv := &http.Server{Addr: addr, Handler: app.secured(mux)}

	go func() {
		log.Printf("listening on http://%s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http server: %v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	if app.client != nil {
		app.client.Disconnect()
	}
}

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "boringNotch", "whatsapp")
}

// secured wraps the mux with two checks. The Host check rejects DNS-rebinding
// attacks: a browser tricked into resolving a hostname to 127.0.0.1 still sends
// the attacker's hostname in the Host header. The token check stops any other
// local process (or a cross-origin fetch) from driving the WhatsApp account.
func (a *App) secured(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(r.Host); err == nil {
			host = h
		}
		if host != "127.0.0.1" && host != "localhost" && host != "::1" {
			http.Error(w, "forbidden host", http.StatusForbidden)
			return
		}
		if a.token != "" && !a.tokenOK(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// tokenOK accepts the secret either as a Bearer header or, for media URLs
// loaded by AVPlayer (which cannot attach headers), a "token" query parameter.
func (a *App) tokenOK(r *http.Request) bool {
	got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if got == "" {
		got = r.URL.Query().Get("token")
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(a.token)) == 1
}

// startWhatsApp opens the session store and connects, starting a QR login when
// no device is paired yet.
func (a *App) startWhatsApp() error {
	ctx := context.Background()
	dbPath := "file:" + filepath.Join(a.dataDir, "store.db") + "?_foreign_keys=on"
	container, err := sqlstore.New(ctx, "sqlite3", dbPath, a.dbLog)
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}
	a.container = container
	return a.connectClient(ctx)
}

// connectClient builds a fresh client from the stored device and either
// connects an existing session or starts a QR login. Safe to call again after
// a logout to re-arm a new QR.
func (a *App) connectClient(ctx context.Context) error {
	device, err := a.container.GetFirstDevice(ctx)
	if err != nil {
		return fmt.Errorf("get device: %w", err)
	}
	a.client = whatsmeow.NewClient(device, a.clientLog)
	a.client.AddEventHandler(a.handleEvent)

	if a.client.Store.ID == nil {
		qrChan, err := a.client.GetQRChannel(ctx)
		if err != nil {
			return fmt.Errorf("qr channel: %w", err)
		}
		if err := a.client.Connect(); err != nil {
			return fmt.Errorf("connect: %w", err)
		}
		go func() {
			for evt := range qrChan {
				if evt.Event == "code" {
					a.mu.Lock()
					a.lastQR = evt.Code
					a.mu.Unlock()
					a.broadcast("qr", evt.Code)
				} else {
					a.mu.Lock()
					a.lastQR = ""
					a.mu.Unlock()
					a.broadcast("qrevent", evt.Event)
					// whatsmeow closes the QR channel after a timeout; without
					// re-arming, the login screen is stuck on a dead code.
					if evt.Event == "timeout" {
						a.client.Disconnect()
						if err := a.connectClient(context.Background()); err != nil {
							log.Printf("qr re-arm failed: %v", err)
						}
					}
				}
			}
		}()
		return nil
	}
	a.mu.Lock()
	a.lastQR = ""
	a.mu.Unlock()
	return a.client.Connect()
}

func (a *App) handleEvent(rawEvt interface{}) {
	switch evt := rawEvt.(type) {
	case *events.Message:
		if m := a.convertMessage(evt); m != nil {
			a.addMessage(*m)
		}
	case *events.Connected, *events.PairSuccess:
		a.broadcast("status", a.statusPayload())
	case *events.Disconnected:
		a.broadcast("status", a.statusPayload())
	case *events.LoggedOut:
		a.broadcast("loggedout", nil)
	case *events.HistorySync:
		a.importHistory(evt)
	}
}

// importHistory ingests the message history WhatsApp pushes automatically after
// a device is linked. This is the standard multi-device sync protocol, so it
// carries no risk of the account being flagged or blocked.
func (a *App) importHistory(evt *events.HistorySync) {
	if evt.Data == nil {
		return
	}
	a.mu.Lock()
	wanted := a.contacts
	a.mu.Unlock()
	cutoff := time.Now().Add(-historyWindow).Unix()
	count := 0
	for _, conv := range evt.Data.GetConversations() {
		chatJID := conv.GetID()
		if j, err := types.ParseJID(chatJID); err == nil {
			chatJID = a.canonicalJID(j)
		}
		// Only import history for chats the notch app is configured to show.
		if len(wanted) > 0 && !wanted[chatJID] {
			continue
		}
		for _, hsm := range conv.GetMessages() {
			wmi := hsm.GetMessage()
			if int64(wmi.GetMessageTimestamp()) < cutoff {
				continue
			}
			if m := a.convertWebMessage(chatJID, wmi); m != nil {
				a.addMessage(*m)
				count++
			}
		}
	}
	if count > 0 {
		log.Printf("imported %d history messages", count)
	}
}

// convertMessage extracts the supported content from a live message event.
// Unsupported message kinds return nil.
func (a *App) convertMessage(evt *events.Message) *Message {
	info := evt.Info
	// For LID-addressed DMs the Chat/Sender JIDs hide the phone number; the
	// Alt fields carry the phone-number form directly, which is what the notch
	// app keys chats by. Groups keep their @g.us JID.
	chat := info.Chat
	if !info.IsGroup && info.Chat.Server == types.HiddenUserServer {
		if info.IsFromMe && !info.RecipientAlt.IsEmpty() {
			chat = info.RecipientAlt
		} else if !info.IsFromMe && !info.SenderAlt.IsEmpty() {
			chat = info.SenderAlt
		}
	}
	m := &Message{
		ID:        info.ID,
		ChatJID:   a.canonicalJID(chat),
		SenderJID: a.canonicalJID(info.Sender),
		FromMe:    info.IsFromMe,
		Timestamp: info.Timestamp.Unix(),
		PushName:  info.PushName,
		Type:      "text",
	}
	a.applyContent(m, evt.Message, true)
	if m.Type == "text" && m.Text == "" {
		return nil // sticker, reaction, protocol message, etc.
	}
	return m
}

// convertWebMessage adapts a history-sync message into the wire format.
func (a *App) convertWebMessage(chatJID string, wmi *waWeb.WebMessageInfo) *Message {
	key := wmi.GetKey()
	if key == nil || key.GetID() == "" {
		return nil
	}
	m := &Message{
		ID:        key.GetID(),
		ChatJID:   chatJID,
		SenderJID: key.GetParticipant(),
		FromMe:    key.GetFromMe(),
		Timestamp: int64(wmi.GetMessageTimestamp()),
		PushName:  wmi.GetPushName(),
		Type:      "text",
	}
	// History is bounded to the last 30 days, so media is recent enough to
	// still download. Expired downloads fail quietly and degrade to a stub.
	a.applyContent(m, wmi.GetMessage(), true)
	if m.Type == "text" && m.Text == "" {
		return nil
	}
	return m
}

// applyContent fills type/text/media on m from a decrypted message body. When
// download is true, attached media is fetched and cached locally.
func (a *App) applyContent(m *Message, wm *waE2E.Message, download bool) {
	if wm == nil {
		return
	}
	// Unwrap container messages (disappearing, view-once, device-sent, edited,
	// document-with-caption, future-proof). Without this, the real content
	// stays buried and the message is dropped as empty.
	for i := 0; i < 4; i++ {
		switch {
		case wm.GetEphemeralMessage().GetMessage() != nil:
			wm = wm.GetEphemeralMessage().GetMessage()
		case wm.GetViewOnceMessage().GetMessage() != nil:
			wm = wm.GetViewOnceMessage().GetMessage()
		case wm.GetViewOnceMessageV2().GetMessage() != nil:
			wm = wm.GetViewOnceMessageV2().GetMessage()
		case wm.GetViewOnceMessageV2Extension().GetMessage() != nil:
			wm = wm.GetViewOnceMessageV2Extension().GetMessage()
		case wm.GetDeviceSentMessage().GetMessage() != nil:
			wm = wm.GetDeviceSentMessage().GetMessage()
		case wm.GetEditedMessage().GetMessage() != nil:
			wm = wm.GetEditedMessage().GetMessage()
		case wm.GetDocumentWithCaptionMessage().GetMessage() != nil:
			wm = wm.GetDocumentWithCaptionMessage().GetMessage()
		default:
			i = 4
		}
	}
	if c := wm.GetConversation(); c != "" {
		m.Text = c
	} else if ext := wm.GetExtendedTextMessage(); ext != nil {
		m.Text = ext.GetText()
	}
	if audio := wm.GetAudioMessage(); audio != nil {
		m.Type = "audio"
		m.Duration = int(audio.GetSeconds())
		if download {
			if path, ct := a.downloadAudio(m.ID, audio); path != "" {
				m.MediaID = m.ID
				m.MediaContentType = ct
			}
		}
	} else if img := wm.GetImageMessage(); img != nil {
		m.Type = "image"
		if m.Text == "" {
			m.Text = img.GetCaption()
		}
		if download {
			if path, ct := a.downloadImage(m.ID, img); path != "" {
				m.MediaID = m.ID
				m.MediaContentType = ct
			}
		}
	}
}

// downloadAudio fetches a voice note and caches it to disk. WhatsApp voice
// notes are Opus-in-Ogg, which AVAudioPlayer cannot decode, so when ffmpeg is
// on PATH the file is transcoded to AAC/m4a.
func (a *App) downloadAudio(id string, audio *waE2E.AudioMessage) (string, string) {
	data, err := a.client.Download(context.Background(), audio)
	if err != nil {
		log.Printf("audio download failed: %v", err)
		return "", ""
	}
	oggPath := filepath.Join(a.mediaDir, id+".ogg")
	if err := os.WriteFile(oggPath, data, 0o600); err != nil {
		log.Printf("audio write failed: %v", err)
		return "", ""
	}
	if ff, err := exec.LookPath("ffmpeg"); err == nil {
		m4aPath := filepath.Join(a.mediaDir, id+".m4a")
		cmd := exec.Command(ff, "-y", "-i", oggPath, "-c:a", "aac", "-b:a", "96k", m4aPath)
		if err := cmd.Run(); err == nil {
			_ = os.Remove(oggPath)
			return m4aPath, "audio/mp4"
		}
	}
	return oggPath, "audio/ogg"
}

// downloadImage fetches a photo and caches it to disk so the UI can display it.
func (a *App) downloadImage(id string, img *waE2E.ImageMessage) (string, string) {
	data, err := a.client.Download(context.Background(), img)
	if err != nil {
		log.Printf("image download failed: %v", err)
		return "", ""
	}
	ct, ext := imageExt(img.GetMimetype())
	path := filepath.Join(a.mediaDir, id+ext)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		log.Printf("image write failed: %v", err)
		return "", ""
	}
	return path, ct
}

// imageExt normalises a MIME type to a (contentType, fileExtension) pair,
// defaulting unknown types to JPEG.
func imageExt(mime string) (string, string) {
	switch mime {
	case "image/png":
		return "image/png", ".png"
	case "image/webp":
		return "image/webp", ".webp"
	case "image/gif":
		return "image/gif", ".gif"
	default:
		return "image/jpeg", ".jpg"
	}
}

// canonicalJID normalizes a JID to its phone-number form. WhatsApp's LID
// addressing hides phone numbers behind "@lid" JIDs; the notch app keys chats
// by the phone-number JID, so LID JIDs are resolved back through the device
// store's LID mapping. Non-LID JIDs are returned unchanged.
func (a *App) canonicalJID(jid types.JID) string {
	if jid.Server == types.HiddenUserServer && a.client != nil {
		if pn, err := a.client.Store.LIDs.GetPNForLID(context.Background(), jid); err == nil && !pn.IsEmpty() {
			return pn.String()
		}
	}
	return jid.String()
}

func (a *App) addMessage(m Message) {
	a.mu.Lock()
	replaced := false
	for i := range a.messages {
		if a.messages[i].ID == m.ID {
			a.messages[i] = m
			replaced = true
			break
		}
	}
	if !replaced {
		a.messages = append(a.messages, m)
	}
	sort.Slice(a.messages, func(i, j int) bool {
		return a.messages[i].Timestamp < a.messages[j].Timestamp
	})
	if len(a.messages) > maxStoredMessages {
		a.messages = a.messages[len(a.messages)-maxStoredMessages:]
	}
	a.mu.Unlock()
	a.saveMessages()
	a.broadcast("message", m)
}

// --- SSE hub ---------------------------------------------------------------

func (a *App) broadcast(typ string, data interface{}) {
	payload, err := json.Marshal(Event{Type: typ, Data: data})
	if err != nil {
		return
	}
	frame := append([]byte("data: "), payload...)
	frame = append(frame, '\n', '\n')
	a.mu.Lock()
	for ch := range a.subs {
		select {
		case ch <- frame:
		default: // drop for a slow consumer rather than block
		}
	}
	a.mu.Unlock()
}

func (a *App) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	// Generous buffer so a history-sync burst is not dropped for a live client.
	ch := make(chan []byte, 4096)
	a.mu.Lock()
	a.subs[ch] = true
	snapshot := append([]Message(nil), a.messages...)
	lastQR := a.lastQR
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.subs, ch)
		a.mu.Unlock()
	}()

	writeFrame := func(typ string, data interface{}) bool {
		payload, err := json.Marshal(Event{Type: typ, Data: data})
		if err != nil {
			return true
		}
		if _, err := fmt.Fprintf(w, "data: %s\n\n", payload); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	if !writeFrame("status", a.statusPayload()) {
		return
	}
	// Replay the pending QR so a client that connects mid-login still sees it.
	if lastQR != "" {
		if !writeFrame("qr", lastQR) {
			return
		}
	}
	// Send stored history as one batch so the client renders it in a single
	// pass and can anchor the view to the newest message without scroll jank.
	if !writeFrame("messages", snapshot) {
		return
	}

	keepAlive := time.NewTicker(15 * time.Second)
	defer keepAlive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case frame := <-ch:
			if _, err := w.Write(frame); err != nil {
				return
			}
			flusher.Flush()
		case <-keepAlive.C:
			if _, err := w.Write([]byte(": ping\n\n")); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// --- HTTP endpoints --------------------------------------------------------

func (a *App) statusPayload() map[string]interface{} {
	connected, loggedIn, selfJID := false, false, ""
	if a.client != nil {
		connected = a.client.IsConnected()
		loggedIn = a.client.IsLoggedIn()
		if a.client.Store.ID != nil {
			selfJID = a.client.Store.ID.String()
		}
	}
	return map[string]interface{}{
		"connected": connected,
		"loggedIn":  loggedIn,
		"selfJID":   selfJID,
	}
}

func (a *App) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, a.statusPayload())
}

func (a *App) handleSend(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		To   string `json:"to"`
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	jid, err := types.ParseJID(body.To)
	if err != nil {
		http.Error(w, "invalid recipient: "+err.Error(), http.StatusBadRequest)
		return
	}
	if a.client == nil {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	resp, err := a.client.SendMessage(context.Background(), jid, &waE2E.Message{
		Conversation: proto.String(body.Text),
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	a.addMessage(Message{
		ID:        resp.ID,
		ChatJID:   jid.String(),
		FromMe:    true,
		Timestamp: resp.Timestamp.Unix(),
		Text:      body.Text,
		Type:      "text",
	})
	writeJSON(w, map[string]string{"id": resp.ID})
}

// handleSendImage accepts a multipart upload (form field "image", plus "to"
// and optional "caption"), uploads the photo to WhatsApp, and sends it.
func (a *App) handleSendImage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(32 << 20); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	jid, err := types.ParseJID(r.FormValue("to"))
	if err != nil {
		http.Error(w, "invalid recipient: "+err.Error(), http.StatusBadRequest)
		return
	}
	if a.client == nil {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	file, header, err := r.FormFile("image")
	if err != nil {
		http.Error(w, "missing image: "+err.Error(), http.StatusBadRequest)
		return
	}
	defer file.Close()
	data, err := io.ReadAll(file)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	mime := header.Header.Get("Content-Type")
	if mime == "" {
		mime = http.DetectContentType(data)
	}
	ct, ext := imageExt(mime)

	uploaded, err := a.client.Upload(context.Background(), data, whatsmeow.MediaImage)
	if err != nil {
		http.Error(w, "upload failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	caption := r.FormValue("caption")
	resp, err := a.client.SendMessage(context.Background(), jid, &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{
			Caption:       proto.String(caption),
			Mimetype:      proto.String(ct),
			URL:           proto.String(uploaded.URL),
			DirectPath:    proto.String(uploaded.DirectPath),
			MediaKey:      uploaded.MediaKey,
			FileEncSHA256: uploaded.FileEncSHA256,
			FileSHA256:    uploaded.FileSHA256,
			FileLength:    proto.Uint64(uint64(len(data))),
		},
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	// Cache the original so the bubble can render without a round trip.
	if err := os.WriteFile(filepath.Join(a.mediaDir, resp.ID+ext), data, 0o600); err != nil {
		log.Printf("sent image cache failed: %v", err)
	}
	a.addMessage(Message{
		ID:               resp.ID,
		ChatJID:          jid.String(),
		FromMe:           true,
		Timestamp:        resp.Timestamp.Unix(),
		Text:             caption,
		Type:             "image",
		MediaID:          resp.ID,
		MediaContentType: ct,
	})
	writeJSON(w, map[string]string{"id": resp.ID})
}

func (a *App) handleMedia(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	// id is used as a filename; reject anything that could escape mediaDir.
	if id != filepath.Base(id) || strings.Contains(id, "..") {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	for _, ext := range []struct{ suffix, ctype string }{
		{".m4a", "audio/mp4"},
		{".ogg", "audio/ogg"},
		{".jpg", "image/jpeg"},
		{".png", "image/png"},
		{".webp", "image/webp"},
		{".gif", "image/gif"},
	} {
		path := filepath.Join(a.mediaDir, id+ext.suffix)
		if _, err := os.Stat(path); err == nil {
			w.Header().Set("Content-Type", ext.ctype)
			http.ServeFile(w, r, path)
			return
		}
	}
	http.Error(w, "not found", http.StatusNotFound)
}

// handleContacts receives the set of chat JIDs the notch app wants to show.
// It scopes history-sync import so unrelated chats are not stored.
func (a *App) handleContacts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		JIDs []string `json:"jids"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	set := make(map[string]bool, len(body.JIDs))
	for _, jid := range body.JIDs {
		if jid != "" {
			set[jid] = true
		}
	}
	a.mu.Lock()
	a.contacts = set
	a.mu.Unlock()
	writeJSON(w, map[string]bool{"ok": true})
}

// handleAvatar serves a contact's WhatsApp profile picture, cached on disk for
// a day. Missing pictures return 404 so the app falls back to a glyph.
func (a *App) handleAvatar(w http.ResponseWriter, r *http.Request) {
	raw := r.URL.Query().Get("jid")
	jid, err := types.ParseJID(raw)
	if err != nil {
		http.Error(w, "invalid jid", http.StatusBadRequest)
		return
	}
	cached := filepath.Join(a.avatarDir, strings.NewReplacer("/", "_", ":", "_", ".", "_").Replace(raw)+".jpg")
	if fi, err := os.Stat(cached); err == nil && time.Since(fi.ModTime()) < 24*time.Hour {
		w.Header().Set("Content-Type", "image/jpeg")
		http.ServeFile(w, r, cached)
		return
	}
	if a.client == nil {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	info, err := a.client.GetProfilePictureInfo(context.Background(), jid, &whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || info == nil || info.URL == "" {
		http.Error(w, "no avatar", http.StatusNotFound)
		return
	}
	resp, err := http.Get(info.URL)
	if err != nil {
		http.Error(w, "fetch failed", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil || len(data) == 0 {
		http.Error(w, "fetch failed", http.StatusBadGateway)
		return
	}
	if err := os.WriteFile(cached, data, 0o600); err != nil {
		log.Printf("avatar cache write failed: %v", err)
	}
	w.Header().Set("Content-Type", "image/jpeg")
	w.Write(data)
}

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	ctx := context.Background()
	if a.client != nil {
		if a.client.Store.ID != nil {
			if err := a.client.Logout(ctx); err != nil {
				log.Printf("logout failed, deleting device: %v", err)
				_ = a.client.Store.Delete(ctx)
			}
		} else {
			// Stuck in a half-paired state: drop the device outright.
			_ = a.client.Store.Delete(ctx)
		}
		a.client.Disconnect()
		a.client = nil
	}
	a.mu.Lock()
	a.messages = nil
	a.lastQR = ""
	a.mu.Unlock()
	a.saveMessages()
	a.broadcast("loggedout", nil)

	// Re-arm a fresh QR login so the user can link again immediately.
	if err := a.connectClient(ctx); err != nil {
		log.Printf("re-login init failed: %v", err)
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// --- persistence -----------------------------------------------------------

func (a *App) messagesPath() string {
	return filepath.Join(a.dataDir, "messages.json")
}

func (a *App) loadMessages() {
	data, err := os.ReadFile(a.messagesPath())
	if err != nil {
		return
	}
	_ = json.Unmarshal(data, &a.messages)
}

func (a *App) saveMessages() {
	a.mu.Lock()
	data, err := json.Marshal(a.messages)
	a.mu.Unlock()
	if err != nil {
		return
	}
	_ = os.WriteFile(a.messagesPath(), data, 0o600)
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
