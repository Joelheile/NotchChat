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
	Duration         int    `json:"duration,omitempty"`
	PushName         string `json:"pushName,omitempty"`
}

// Event is one Server-Sent-Events frame.
type Event struct {
	Type string      `json:"type"`
	Data interface{} `json:"data,omitempty"`
}

type App struct {
	client    *whatsmeow.Client
	dataDir   string
	mediaDir  string
	token     string
	port      int
	clientLog waLog.Logger
	dbLog     waLog.Logger

	mu       sync.Mutex
	subs     map[chan []byte]bool
	messages []Message
}

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
		token:     *token,
		port:      *port,
		clientLog: waLog.Stdout("Client", "WARN", true),
		dbLog:     waLog.Stdout("DB", "WARN", true),
		subs:      map[chan []byte]bool{},
	}
	if err := os.MkdirAll(app.mediaDir, 0o700); err != nil {
		log.Fatalf("cannot create media dir: %v", err)
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
	mux.HandleFunc("/media", app.handleMedia)
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
	device, err := container.GetFirstDevice(ctx)
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
					a.broadcast("qr", evt.Code)
				} else {
					a.broadcast("qrevent", evt.Event)
				}
			}
		}()
		return nil
	}
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
	}
}

// convertMessage extracts the supported content from a live message event.
// Unsupported message kinds return nil.
func (a *App) convertMessage(evt *events.Message) *Message {
	info := evt.Info
	m := &Message{
		ID:        info.ID,
		ChatJID:   info.Chat.String(),
		SenderJID: info.Sender.String(),
		FromMe:    info.IsFromMe,
		Timestamp: info.Timestamp.Unix(),
		PushName:  info.PushName,
		Type:      "text",
	}
	wm := evt.Message
	if c := wm.GetConversation(); c != "" {
		m.Text = c
	} else if ext := wm.GetExtendedTextMessage(); ext != nil {
		m.Text = ext.GetText()
	}
	if audio := wm.GetAudioMessage(); audio != nil {
		m.Type = "audio"
		m.Duration = int(audio.GetSeconds())
		if path, ct := a.downloadAudio(info.ID, audio); path != "" {
			m.MediaID = info.ID
			m.MediaContentType = ct
		}
	} else if img := wm.GetImageMessage(); img != nil {
		m.Type = "image"
		if m.Text == "" {
			m.Text = img.GetCaption()
		}
	}
	if m.Type == "text" && m.Text == "" {
		return nil // sticker, reaction, protocol message, etc.
	}
	return m
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

	ch := make(chan []byte, 64)
	a.mu.Lock()
	a.subs[ch] = true
	snapshot := append([]Message(nil), a.messages...)
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
	for _, m := range snapshot {
		if !writeFrame("message", m) {
			return
		}
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

func (a *App) handleLogout(w http.ResponseWriter, r *http.Request) {
	if a.client != nil {
		_ = a.client.Logout(context.Background())
	}
	a.mu.Lock()
	a.messages = nil
	a.mu.Unlock()
	a.saveMessages()
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
