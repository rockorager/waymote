package main

import (
	"context"
	"embed"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/coder/websocket"
	"golang.org/x/sys/unix"
)

const (
	protocolVersion       = 2
	videoMessage          = 1
	audioMessage          = 2
	videoHeaderSize       = 40
	audioHeaderSize       = 24
	maximumAccessUnitSize = 16 << 20
	rtpPayloadType        = 96
	audioRTPPayloadType   = 97
	audioSampleRate       = 48_000
	audioFrameNanos       = 20 * time.Millisecond
	audioClockCorrection  = time.Millisecond
	audioClockWindow      = 5 * time.Second
	maximumAudioPacket    = 4096
	controlSize           = 16
	streamEventHeaderSize = 8
	maximumClipboardBytes = 1 << 20
	controlAcquire        = "acquire"
	controlRelease        = "release"

	controlPointerMotion   = 1
	controlPointerButton   = 2
	controlPointerScroll   = 3
	controlKeyboardKey     = 4
	controlReleaseAll      = 5
	controlResize          = 6
	controlClipboard       = 7
	controlPointerRelative = 8
	controlQuality         = 9
	controlText            = 10
	controlKeyframeReady   = 11
	streamClipboard        = 1
	streamFrameMetadata    = 2
	streamResizeApplied    = 3
	maximumTextBytes       = 4000
	minimumOutputWidth     = 320
	maximumOutputWidth     = 6000
	minimumOutputHeight    = 180
	maximumOutputHeight    = 6000
	maximumOutputPixels    = maximumOutputWidth * maximumOutputHeight
	minimumOutputScale     = 120
	maximumOutputScale     = 480
)

var version = "0.0.0-dev"

//go:embed sdk/* examples/web/*
var assets embed.FS

type sample struct {
	data          []byte
	key           bool
	discontinuity bool
	sequence      uint64
	timestamp     uint64
	generation    uint32
	width         uint16
	height        uint16
	captureNanos  uint64
	inputSequence uint32
}

type frameMetadata struct {
	generation             uint32
	width, height          uint16
	captureNanos, sequence uint64
	inputSequence          uint32
	fps                    uint32
}

type subscriber struct {
	frames             chan sample
	waitingForKeyframe bool
}

type audioSample struct {
	data          []byte
	discontinuity bool
	sequence      uint64
	timestamp     uint64
	generation    uint32
}

type audioSubscriber struct {
	packets chan audioSample
}

type audioHub struct {
	mu          sync.Mutex
	subscribers map[*audioSubscriber]struct{}
}

func newAudioHub() *audioHub {
	return &audioHub{subscribers: make(map[*audioSubscriber]struct{})}
}

func (h *audioHub) subscribe() *audioSubscriber {
	subscriber := &audioSubscriber{packets: make(chan audioSample, 8)}
	h.mu.Lock()
	h.subscribers[subscriber] = struct{}{}
	h.mu.Unlock()
	return subscriber
}

func (h *audioHub) unsubscribe(subscriber *audioSubscriber) {
	h.mu.Lock()
	delete(h.subscribers, subscriber)
	h.mu.Unlock()
}

func (h *audioHub) broadcast(packet audioSample) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for subscriber := range h.subscribers {
		outgoing := packet
		select {
		case subscriber.packets <- outgoing:
		default:
			drainAudioPackets(subscriber.packets)
			outgoing.discontinuity = true
			subscriber.packets <- outgoing
		}
	}
}

func drainAudioPackets(packets chan audioSample) {
	for {
		select {
		case <-packets:
		default:
			return
		}
	}
}

type hub struct {
	mu          sync.Mutex
	subscribers map[*subscriber]struct{}
	latestGOP   []sample
}

func newHub() *hub {
	return &hub{subscribers: make(map[*subscriber]struct{})}
}

func (h *hub) subscribe() (*subscriber, []sample) {
	subscriber := &subscriber{frames: make(chan sample, 8)}
	h.mu.Lock()
	bootstrap := append([]sample(nil), h.latestGOP...)
	h.subscribers[subscriber] = struct{}{}
	h.mu.Unlock()
	return subscriber, bootstrap
}

func (h *hub) unsubscribe(subscriber *subscriber) {
	h.mu.Lock()
	delete(h.subscribers, subscriber)
	h.mu.Unlock()
}

func (h *hub) broadcast(frame sample) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if frame.discontinuity || len(h.latestGOP) > 0 && h.latestGOP[0].generation != frame.generation {
		h.latestGOP = nil
	}
	if frame.key {
		h.latestGOP = append(make([]sample, 0, 241), frame)
	} else if len(h.latestGOP) > 0 {
		// The encoder keyframe interval is bounded to at most 240 frames.
		// If that invariant is ever broken, discard the stale bootstrap
		// rather than retaining an unbounded stream.
		if len(h.latestGOP) < 241 {
			h.latestGOP = append(h.latestGOP, frame)
		} else {
			h.latestGOP = h.latestGOP[:0]
		}
	}
	for subscriber := range h.subscribers {
		outgoing := frame
		if subscriber.waitingForKeyframe {
			if !frame.key {
				continue
			}
			outgoing.discontinuity = true
			subscriber.waitingForKeyframe = false
		}
		select {
		case subscriber.frames <- outgoing:
		default:
			// Drop the stale dependent frames, then resume this connection at
			// the next keyframe instead of turning congestion into a reconnect
			// loop on a reliable transport.
			drainFrames(subscriber.frames)
			subscriber.waitingForKeyframe = true
		}
	}
	return len(h.latestGOP) > 0 && h.latestGOP[0].generation == frame.generation
}

func drainFrames(frames chan sample) {
	for {
		select {
		case <-frames:
		default:
			return
		}
	}
}

type gateway struct {
	hub           *hub
	audio         *audioHub
	audioEnabled  bool
	input         *inputBridge
	clipboard     *clipboardBridge
	frameRate     uint64
	allowedOrigin string
	fixedWidth    uint32
	fixedHeight   uint32
	nextClientID  atomic.Uint64
	controllerMu  sync.Mutex
	controller    bool
	quality       qualityPolicy
	events        *messageBridge
}

type messageBridge struct {
	mu   sync.Mutex
	sink chan []byte
}

func (b *messageBridge) attach(s chan []byte) { b.mu.Lock(); b.sink = s; b.mu.Unlock() }
func (b *messageBridge) detach(s chan []byte) {
	b.mu.Lock()
	if b.sink == s {
		b.sink = nil
	}
	b.mu.Unlock()
}
func (b *messageBridge) publish(m []byte) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.sink != nil {
		replaceQueued(b.sink, m)
	}
}

type qualityPolicy struct {
	bitrate, fps, scale uint32
	maxBitrate, maxFPS  uint32
	bad, good           int
	last                time.Time
}

func (p *qualityPolicy) update(queue uint32, dropped uint64, renderedFPS float64, rtt float64, active bool, now time.Time) bool {
	// Presentation scheduling intentionally drops stale frames to preserve
	// latency. Those drops are not evidence of network congestion; decoder
	// backlog and sustained RTT are. React conservatively and sacrifice one
	// quality dimension at a time, preserving sharp text as long as possible.
	bad := queue >= 5 || rtt > 250
	good := active && queue <= 1 && dropped == 0 && rtt < 120 && renderedFPS >= float64(p.fps)*0.9
	if bad {
		p.bad++
		p.good = 0
	} else if good {
		p.good++
		p.bad = 0
	} else {
		p.bad = 0
		p.good = 0
	}
	if now.Sub(p.last) < 5*time.Second {
		return false
	}
	if p.bad >= 2 {
		minimumBitrate := max(uint32(300), p.maxBitrate/2)
		if p.bitrate > minimumBitrate {
			p.bitrate = max(minimumBitrate, p.bitrate*80/100)
		} else if p.fps > 20 {
			p.fps -= 10
		} else if p.scale > 50 {
			p.scale -= 25
		}
		p.bad = 0
		p.last = now
		return true
	}
	if p.good >= 8 {
		p.bitrate = min(p.maxBitrate, p.bitrate*110/100)
		if p.scale < 100 {
			p.scale += 25
		} else if p.fps < p.maxFPS {
			p.fps = min(p.maxFPS, p.fps+10)
		}
		p.good = 0
		p.last = now
		return true
	}
	return false
}

func (g *gateway) stream(w http.ResponseWriter, r *http.Request) {
	clientID := g.nextClientID.Add(1)
	originPatterns := []string(nil)
	if g.allowedOrigin != "" {
		originPatterns = []string{g.allowedOrigin}
	}
	connection, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
		OriginPatterns:  originPatterns,
	})
	if err != nil {
		log.Printf("video client %d rejected: %v", clientID, err)
		return
	}
	defer connection.CloseNow()
	log.Printf("video client %d connected: user-agent=%q", clientID, r.UserAgent())
	defer log.Printf("video client %d disconnected", clientID)
	connection.SetReadLimit(4 << 10)
	ctx := connection.CloseRead(r.Context())

	configuration, _ := json.Marshal(map[string]any{
		"type":      "video-config",
		"version":   protocolVersion,
		"codec":     "avc1.42E032",
		"frameRate": g.frameRate,
	})
	if err := connection.Write(ctx, websocket.MessageText, configuration); err != nil {
		log.Printf("video client %d configuration write failed: %v", clientID, err)
		return
	}

	subscriber, bootstrap := g.hub.subscribe()
	defer g.hub.unsubscribe(subscriber)
	waitingForKeyframe := true
	writeFrame := func(frame sample) error {
		if waitingForKeyframe && !frame.key {
			return nil
		}
		waitingForKeyframe = false
		return connection.Write(ctx, websocket.MessageBinary, encodeVideoMessage(frame))
	}
	for _, frame := range bootstrap {
		if err := writeFrame(frame); err != nil {
			log.Printf("video client %d bootstrap write failed: %v", clientID, err)
			return
		}
	}
	for {
		select {
		case <-ctx.Done():
			log.Printf("video client %d read side closed: %v", clientID, ctx.Err())
			return
		case frame, ok := <-subscriber.frames:
			if !ok {
				log.Printf("video client %d frame subscription closed", clientID)
				return
			}
			if err := writeFrame(frame); err != nil {
				log.Printf(
					"video client %d video write failed (status %d): %v",
					clientID,
					websocket.CloseStatus(err),
					err,
				)
				return
			}
		}
	}
}

func encodeVideoMessage(frame sample) []byte {
	message := make([]byte, videoHeaderSize+len(frame.data))
	message[0] = protocolVersion
	message[1] = videoMessage
	if frame.key {
		message[2] = 1
	}
	if frame.discontinuity {
		message[2] |= 2
	}
	binary.LittleEndian.PutUint64(message[4:12], frame.sequence)
	binary.LittleEndian.PutUint64(message[12:20], frame.timestamp)
	binary.LittleEndian.PutUint32(message[20:24], frame.generation)
	binary.LittleEndian.PutUint16(message[24:26], frame.width)
	binary.LittleEndian.PutUint16(message[26:28], frame.height)
	binary.LittleEndian.PutUint64(message[28:36], frame.captureNanos)
	binary.LittleEndian.PutUint32(message[36:40], frame.inputSequence)
	copy(message[videoHeaderSize:], frame.data)
	return message
}

func encodeAudioMessage(packet audioSample) []byte {
	message := make([]byte, audioHeaderSize+len(packet.data))
	message[0] = protocolVersion
	message[1] = audioMessage
	if packet.discontinuity {
		message[2] = 1
	}
	binary.LittleEndian.PutUint64(message[4:12], packet.sequence)
	binary.LittleEndian.PutUint64(message[12:20], packet.timestamp)
	binary.LittleEndian.PutUint32(message[20:24], packet.generation)
	copy(message[audioHeaderSize:], packet.data)
	return message
}

func (g *gateway) streamAudio(w http.ResponseWriter, r *http.Request) {
	clientID := g.nextClientID.Add(1)
	originPatterns := []string(nil)
	if g.allowedOrigin != "" {
		originPatterns = []string{g.allowedOrigin}
	}
	connection, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
		OriginPatterns:  originPatterns,
	})
	if err != nil {
		log.Printf("audio client %d rejected: %v", clientID, err)
		return
	}
	defer connection.CloseNow()
	log.Printf("audio client %d connected: user-agent=%q", clientID, r.UserAgent())
	defer log.Printf("audio client %d disconnected", clientID)
	connection.SetReadLimit(1024)
	ctx := connection.CloseRead(r.Context())
	configuration, _ := json.Marshal(map[string]any{
		"type":       "audio-config",
		"version":    protocolVersion,
		"enabled":    g.audioEnabled,
		"codec":      "opus",
		"sampleRate": audioSampleRate,
		"channels":   2,
	})
	if err := connection.Write(ctx, websocket.MessageText, configuration); err != nil {
		return
	}
	if !g.audioEnabled {
		<-ctx.Done()
		return
	}
	subscriber := g.audio.subscribe()
	defer g.audio.unsubscribe(subscriber)
	for {
		select {
		case <-ctx.Done():
			return
		case packet := <-subscriber.packets:
			if err := connection.Write(ctx, websocket.MessageBinary, encodeAudioMessage(packet)); err != nil {
				log.Printf("audio client %d write failed: %v", clientID, err)
				return
			}
		}
	}
}

type inputBridge struct {
	mu     sync.Mutex
	writer io.WriteCloser
}

type videoPublisher struct {
	hub             *hub
	input           *inputBridge
	readyGeneration uint32
}

func (publisher *videoPublisher) publish(frame sample) error {
	ready := publisher.hub.broadcast(frame)
	if ready && frame.generation == publisher.readyGeneration {
		return nil
	}
	if ready {
		if err := publisher.input.write(encodeKeyframeReadiness(frame.generation, true)); err != nil {
			return err
		}
		publisher.readyGeneration = frame.generation
		return nil
	}
	if publisher.readyGeneration == 0 {
		return nil
	}
	if err := publisher.input.write(encodeKeyframeReadiness(publisher.readyGeneration, false)); err != nil {
		return err
	}
	publisher.readyGeneration = 0
	return nil
}

type clipboardBridge struct {
	mu        sync.Mutex
	latest    []byte
	hasLatest bool
	sink      chan []byte
}

func (bridge *clipboardBridge) publish(text []byte) {
	message := encodeClipboardMessage(text)
	bridge.mu.Lock()
	bridge.latest = append(bridge.latest[:0], message...)
	bridge.hasLatest = true
	if bridge.sink != nil {
		replaceQueued(bridge.sink, message)
	}
	bridge.mu.Unlock()
}

func (bridge *clipboardBridge) attach(sink chan []byte) {
	bridge.mu.Lock()
	bridge.sink = sink
	if bridge.hasLatest {
		replaceQueued(sink, bridge.latest)
	}
	bridge.mu.Unlock()
}

func (bridge *clipboardBridge) detach(sink chan []byte) {
	bridge.mu.Lock()
	if bridge.sink == sink {
		bridge.sink = nil
	}
	bridge.mu.Unlock()
}

func replaceQueued(destination chan []byte, message []byte) {
	owned := append([]byte(nil), message...)
	select {
	case destination <- owned:
		return
	default:
	}
	select {
	case <-destination:
	default:
	}
	destination <- owned
}

func encodeClipboardMessage(text []byte) []byte {
	message, _ := json.Marshal(map[string]string{
		"type": "clipboard",
		"text": string(text),
	})
	return message
}

func (bridge *inputBridge) attach(writer io.WriteCloser) {
	bridge.mu.Lock()
	bridge.writer = writer
	bridge.mu.Unlock()
}

func (bridge *inputBridge) detach() {
	bridge.mu.Lock()
	writer := bridge.writer
	bridge.writer = nil
	bridge.mu.Unlock()
	if writer != nil {
		_ = writer.Close()
	}
}

func (bridge *inputBridge) write(record []byte) error {
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.writer == nil {
		return errors.New("input process is unavailable")
	}
	for len(record) > 0 {
		count, err := bridge.writer.Write(record)
		if err != nil {
			return err
		}
		if count == 0 {
			return io.ErrShortWrite
		}
		record = record[count:]
	}
	return nil
}

func (g *gateway) control(w http.ResponseWriter, r *http.Request) {
	clientID := g.nextClientID.Add(1)
	originPatterns := []string(nil)
	if g.allowedOrigin != "" {
		originPatterns = []string{g.allowedOrigin}
	}
	connection, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
		OriginPatterns:  originPatterns,
	})
	if err != nil {
		log.Printf("control client %d rejected: %v", clientID, err)
		return
	}
	defer connection.CloseNow()
	log.Printf("control client %d connected: user-agent=%q", clientID, r.UserAgent())
	defer log.Printf("control client %d disconnected", clientID)
	ctx, cancel := context.WithCancel(r.Context())
	stateMessages := make(chan []byte, 4)
	clipboardMessages := make(chan []byte, 1)
	writerDone := make(chan error, 1)
	go func() {
		writerDone <- writeControlMessages(ctx, connection, stateMessages, clipboardMessages)
		cancel()
	}()
	defer func() {
		cancel()
		<-writerDone
	}()
	controlling := false
	release := func() {
		if !controlling {
			return
		}
		if g.clipboard != nil {
			g.clipboard.detach(clipboardMessages)
		}
		if g.events != nil {
			g.events.detach(stateMessages)
		}
		if err := g.input.write(releaseAllRecord()); err != nil {
			log.Printf("control client %d release-all failed: %v", clientID, err)
		}
		g.releaseController()
		controlling = false
	}
	defer release()

	connection.SetReadLimit(6*maximumClipboardBytes + 4096)
	for {
		messageType, message, err := connection.Read(ctx)
		if err != nil {
			return
		}
		if messageType == websocket.MessageText {
			var envelope struct {
				Type, Action, Text string
				ID                 uint64
				Queue              uint32
				Dropped            uint64
				FPS, RTT           float64
				Active             bool
				Sequence           uint32
			}
			unmarshalErr := json.Unmarshal(message, &envelope)
			if envelope.Type == "ping" {
				serverNanos, err := monotonicNanos()
				if unmarshalErr != nil || err != nil {
					continue
				}
				reply, _ := json.Marshal(map[string]any{
					"type":        "pong",
					"id":          envelope.ID,
					"serverNanos": strconv.FormatUint(serverNanos, 10),
				})
				if !queueControlMessage(ctx, stateMessages, reply) {
					return
				}
				continue
			}
			if envelope.Type == "feedback" {
				if unmarshalErr != nil || !controlling || envelope.Queue > 64 || envelope.Dropped > 10000 ||
					math.IsNaN(envelope.FPS) || math.IsInf(envelope.FPS, 0) || envelope.FPS < 0 || envelope.FPS > 1000 ||
					math.IsNaN(envelope.RTT) || math.IsInf(envelope.RTT, 0) || envelope.RTT < 0 || envelope.RTT > 60_000 {
					continue
				}
				if g.quality.update(envelope.Queue, envelope.Dropped, envelope.FPS, envelope.RTT, envelope.Active, time.Now()) {
					record := encodeQuality(g.quality)
					if err := g.input.write(record); err != nil {
						return
					}
				}
				quality, _ := json.Marshal(map[string]any{"type": "quality", "bitrate": g.quality.bitrate, "fps": g.quality.fps, "scale": g.quality.scale})
				if !queueControlMessage(ctx, stateMessages, quality) {
					return
				}
				continue
			}
			if envelope.Type == "text" {
				if !controlling {
					continue
				}
				framed, err := encodeTextInput(envelope.Action, envelope.Text, envelope.Sequence)
				if err != nil {
					_ = connection.Close(websocket.StatusUnsupportedData, "invalid text")
					return
				}
				if err := g.input.write(framed); err != nil {
					return
				}
				continue
			}
			switch string(message) {
			case controlAcquire:
				if controlling {
					if !queueControlMessage(ctx, stateMessages, controlStateMessage("active")) {
						return
					}
				} else if g.claimController() {
					controlling = true
					if g.clipboard != nil {
						g.clipboard.attach(clipboardMessages)
					}
					if g.events != nil {
						g.events.attach(stateMessages)
					}
					if !queueControlMessage(ctx, stateMessages, controlStateMessage("active")) {
						return
					}
				} else {
					if !queueControlMessage(ctx, stateMessages, controlStateMessage("busy")) {
						return
					}
				}
			case controlRelease:
				release()
				if !queueControlMessage(ctx, stateMessages, controlStateMessage("ready")) {
					return
				}
			default:
				text, err := decodeClipboardRequest(message)
				if err != nil {
					log.Printf("control client %d sent an invalid control command", clientID)
					_ = connection.Close(websocket.StatusUnsupportedData, "invalid control command")
					return
				}
				if controlling {
					if err := g.input.write(encodeClipboardInput(text)); err != nil {
						log.Printf("control client %d clipboard write failed: %v", clientID, err)
						_ = connection.Close(websocket.StatusInternalError, "input process unavailable")
						return
					}
				}
			}
			continue
		}
		if messageType != websocket.MessageBinary || !validControlRecord(message) {
			log.Printf("control client %d sent an invalid input record", clientID)
			_ = connection.Close(websocket.StatusUnsupportedData, "invalid input record")
			return
		}
		if !controlling {
			continue
		}
		message = fixedResizeRecord(message, g.fixedWidth, g.fixedHeight)
		if err := g.input.write(message); err != nil {
			log.Printf("control client %d input write failed: %v", clientID, err)
			_ = connection.Close(websocket.StatusInternalError, "input process unavailable")
			return
		}
	}
}

func encodeQuality(p qualityPolicy) []byte {
	r := make([]byte, 16)
	r[0] = protocolVersion
	r[1] = controlQuality
	binary.LittleEndian.PutUint32(r[4:8], p.bitrate)
	binary.LittleEndian.PutUint32(r[8:12], p.fps)
	binary.LittleEndian.PutUint32(r[12:16], p.scale)
	return r
}

func encodeKeyframeReadiness(generation uint32, ready bool) []byte {
	record := make([]byte, controlSize)
	record[0] = protocolVersion
	record[1] = controlKeyframeReady
	if ready {
		record[2] = 1
	}
	binary.LittleEndian.PutUint32(record[4:8], generation)
	return record
}

func encodeTextInput(action, text string, sequence uint32) ([]byte, error) {
	if action != "preedit" && action != "commit" || len(text) > maximumTextBytes || !utf8.ValidString(text) || strings.IndexByte(text, 0) >= 0 {
		return nil, errors.New("invalid text")
	}
	r := make([]byte, controlSize+len(text))
	r[0] = protocolVersion
	r[1] = controlText
	if action == "preedit" {
		r[2] = 1
	}
	binary.LittleEndian.PutUint32(r[4:8], uint32(len(text)))
	binary.LittleEndian.PutUint32(r[8:12], sequence)
	copy(r[16:], text)
	return r, nil
}

func controlStateMessage(state string) []byte {
	message, _ := json.Marshal(map[string]string{
		"type":  "control-state",
		"state": state,
	})
	return message
}

func queueControlMessage(ctx context.Context, destination chan []byte, message []byte) bool {
	select {
	case destination <- message:
		return true
	case <-ctx.Done():
		return false
	}
}

func writeControlMessages(
	ctx context.Context,
	connection *websocket.Conn,
	stateMessages <-chan []byte,
	clipboardMessages <-chan []byte,
) error {
	for {
		var message []byte
		select {
		case message = <-stateMessages:
		case message = <-clipboardMessages:
		case <-ctx.Done():
			return ctx.Err()
		}
		if err := connection.Write(ctx, websocket.MessageText, message); err != nil {
			return err
		}
	}
}

func decodeClipboardRequest(message []byte) ([]byte, error) {
	var request struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(message, &request); err != nil {
		return nil, err
	}
	if request.Type != "clipboard-write" || len(request.Text) > maximumClipboardBytes ||
		!utf8.ValidString(request.Text) {
		return nil, errors.New("invalid clipboard request")
	}
	return []byte(request.Text), nil

}

func encodeClipboardInput(text []byte) []byte {
	message := make([]byte, controlSize+len(text))
	message[0] = protocolVersion
	message[1] = controlClipboard
	binary.LittleEndian.PutUint32(message[4:8], uint32(len(text)))
	copy(message[controlSize:], text)
	return message
}

func (g *gateway) claimController() bool {
	g.controllerMu.Lock()
	defer g.controllerMu.Unlock()
	if g.controller {
		return false
	}
	g.controller = true
	return true
}

func (g *gateway) releaseController() {
	g.controllerMu.Lock()
	g.controller = false
	g.controllerMu.Unlock()
}

func validControlRecord(record []byte) bool {
	if len(record) != controlSize || record[0] != protocolVersion || record[3] != 0 || record[2] > 2 {
		return false
	}
	a := binary.LittleEndian.Uint32(record[4:8])
	b := binary.LittleEndian.Uint32(record[8:12])
	c := binary.LittleEndian.Uint32(record[12:16])
	state := record[2]
	switch record[1] {
	case controlPointerMotion:
		return state == 0 && a <= 65_535 && b <= 65_535 && c != 0
	case controlPointerRelative:
		dx, dy := math.Float32frombits(a), math.Float32frombits(b)
		return state == 0 && !floatOutOfRange(dx) && !floatOutOfRange(dy) && c != 0
	case controlPointerButton:
		return state <= 1 && a >= 0x110 && a <= 0x114 && b == 0 && c != 0
	case controlPointerScroll:
		dx := math.Float32frombits(a)
		dy := math.Float32frombits(b)
		return state == 0 && !floatOutOfRange(dx) && !floatOutOfRange(dy) && c != 0
	case controlKeyboardKey:
		return a > 0 && a < 256 && b == 0 && c != 0
	case controlReleaseAll:
		return state == 0 && a == 0 && b == 0 && c == 0
	case controlResize:
		return state == 0 &&
			a >= minimumOutputWidth && a <= maximumOutputWidth && a%2 == 0 &&
			b >= minimumOutputHeight && b <= maximumOutputHeight && b%2 == 0 &&
			uint64(a)*uint64(b) <= maximumOutputPixels &&
			(c&0xffff) >= minimumOutputScale && (c&0xffff) <= maximumOutputScale &&
			c>>16 != 0
	default:
		return false
	}
}

func floatOutOfRange(value float32) bool {
	return math.IsNaN(float64(value)) || math.IsInf(float64(value), 0) || math.Abs(float64(value)) > 4096
}

func releaseAllRecord() []byte {
	record := make([]byte, controlSize)
	record[0] = protocolVersion
	record[1] = controlReleaseAll
	return record
}

func fixedResizeRecord(record []byte, width, height uint32) []byte {
	if width == 0 || len(record) != controlSize || record[1] != controlResize {
		return record
	}
	fixed := append([]byte(nil), record...)
	binary.LittleEndian.PutUint32(fixed[4:8], width)
	binary.LittleEndian.PutUint32(fixed[8:12], height)
	request := binary.LittleEndian.Uint32(fixed[12:16]) & 0xffff0000
	binary.LittleEndian.PutUint32(fixed[12:16], request|120)
	return fixed
}

func main() {
	listenAddress := flag.String("listen", "127.0.0.1:8080", "HTTP listen address")
	streamdPath := flag.String("streamd", "waymote-streamd", "path to waymote-streamd")
	frameRate := flag.Uint64("frame-rate", 30, "capture and encoder frame rate")
	bitrate := flag.Uint64("bitrate", 12000, "encoder target bitrate in kbps")
	fixedWidth := flag.Uint("fixed-width", 0, "fixed output width (zero allows client resizing)")
	fixedHeight := flag.Uint("fixed-height", 0, "fixed output height (zero allows client resizing)")
	audioSource := flag.String("audio-source", os.Getenv("WAYMOTE_AUDIO_SOURCE"), "PulseAudio monitor source (empty disables audio)")
	xkbLayout := flag.String("xkb-layout", os.Getenv("XKB_DEFAULT_LAYOUT"), "XKB keyboard layout")
	publicURL := flag.String("public-url", os.Getenv("PUBLIC_URL"), "public gateway URL allowed as a WebSocket origin")
	showVersion := flag.Bool("version", false, "show the Waymote version")
	flag.Parse()
	if *showVersion {
		fmt.Printf("waymote-gateway %s (protocol %d)\n", version, protocolVersion)
		return
	}
	if *frameRate == 0 || *frameRate > 240 {
		log.Fatal("frame-rate must be between 1 and 240")
	}
	if *bitrate < 100 || *bitrate > 200_000 {
		log.Fatal("bitrate must be between 100 and 200000 kbps")
	}
	if (*fixedWidth == 0) != (*fixedHeight == 0) ||
		*fixedWidth != 0 && (*fixedWidth < minimumOutputWidth ||
			*fixedWidth > maximumOutputWidth || *fixedWidth%2 != 0 ||
			*fixedHeight < minimumOutputHeight || *fixedHeight > maximumOutputHeight ||
			*fixedHeight%2 != 0 ||
			uint64(*fixedWidth)*uint64(*fixedHeight) > maximumOutputPixels) {
		log.Fatalf(
			"fixed output size must be even, within %dx%d and %dx%d, and at most %d pixels",
			minimumOutputWidth,
			minimumOutputHeight,
			maximumOutputWidth,
			maximumOutputHeight,
			maximumOutputPixels,
		)
	}
	if *xkbLayout == "" {
		*xkbLayout = "us"
	}
	if !validXKBLayout(*xkbLayout) {
		log.Fatal("invalid xkb-layout")
	}
	allowedOrigin, err := parseAllowedOrigin(*publicURL)
	if err != nil {
		log.Fatalf("invalid public-url: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	hub := newHub()
	audio := newAudioHub()
	input := &inputBridge{}
	clipboard := &clipboardBridge{}
	events := &messageBridge{}
	go func() {
		if err := runEncoder(ctx, hub, audio, input, clipboard, events, *streamdPath, *frameRate, *bitrate, *xkbLayout, *audioSource); err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("stream encoder stopped: %v", err)
			stop()
		}
	}()

	sdkRoot, err := fs.Sub(assets, "sdk")
	if err != nil {
		log.Fatal(err)
	}
	exampleRoot, err := fs.Sub(assets, "examples/web")
	if err != nil {
		log.Fatal(err)
	}
	gateway := &gateway{
		hub:           hub,
		audio:         audio,
		audioEnabled:  *audioSource != "",
		input:         input,
		clipboard:     clipboard,
		frameRate:     *frameRate,
		allowedOrigin: allowedOrigin,
		fixedWidth:    uint32(*fixedWidth),
		fixedHeight:   uint32(*fixedHeight),
		quality: qualityPolicy{
			bitrate: uint32(*bitrate), fps: uint32(*frameRate), scale: 100,
			maxBitrate: uint32(*bitrate), maxFPS: uint32(*frameRate),
		},
		events: events,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = io.WriteString(w, "ok\n")
	})
	mux.HandleFunc("/stream", gateway.stream)
	mux.HandleFunc("/audio", gateway.streamAudio)
	mux.HandleFunc("/control", gateway.control)
	sdkFiles := http.FileServerFS(sdkRoot)
	mux.Handle("/waymote.js", sdkFiles)
	mux.Handle("/waymote.d.ts", sdkFiles)
	mux.Handle("/audio-player.js", sdkFiles)
	mux.Handle("/", http.FileServerFS(exampleRoot))

	server := &http.Server{
		Addr:              *listenAddress,
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	go func() {
		<-ctx.Done()
		shutdownContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownContext)
	}()
	log.Printf("Waymote gateway listening on http://%s", *listenAddress)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func validXKBLayout(layout string) bool {
	if len(layout) == 0 || len(layout) > 32 {
		return false
	}
	for _, c := range layout {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func parseAllowedOrigin(rawURL string) (string, error) {
	if rawURL == "" {
		return "", nil
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	if (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil {
		return "", fmt.Errorf("must be an absolute HTTP(S) URL")
	}
	return parsed.Scheme + "://" + parsed.Host, nil
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self'; img-src 'self' data:")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func runEncoder(
	ctx context.Context,
	hub *hub,
	audio *audioHub,
	input *inputBridge,
	clipboard *clipboardBridge,
	events *messageBridge,
	streamdPath string,
	frameRate uint64,
	bitrate uint64,
	xkbLayout string,
	audioSource string,
) error {
	rtp, rtpPort, err := listenLoopbackRTP()
	if err != nil {
		return err
	}
	defer rtp.Close()
	arguments := []string{
		"--frame-rate",
		strconv.FormatUint(frameRate, 10),
		"--bitrate",
		strconv.FormatUint(bitrate, 10),
		"--rtp-port",
		strconv.Itoa(rtpPort),
		"--xkb-layout",
		xkbLayout,
	}
	var audioRTP *net.UDPConn
	if audioSource != "" {
		var audioPort int
		audioRTP, audioPort, err = listenLoopbackRTP()
		if err != nil {
			return err
		}
		defer audioRTP.Close()
		arguments = append(arguments,
			"--audio-rtp-port", strconv.Itoa(audioPort),
			"--audio-source", audioSource,
		)
	}
	command := exec.CommandContext(ctx, streamdPath, arguments...)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return os.ErrProcessDone
		}
		err := syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	command.Stderr = os.Stderr
	control, err := command.StdinPipe()
	if err != nil {
		return err
	}
	streamEvents, err := command.StdoutPipe()
	if err != nil {
		_ = control.Close()
		return err
	}
	if err := command.Start(); err != nil {
		_ = control.Close()
		return err
	}
	input.attach(control)
	defer input.detach()
	parseError := make(chan error, 1)
	runContext, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	metadata := make(chan frameMetadata, 120)
	publisher := &videoPublisher{hub: hub, input: input}
	go func() {
		parseError <- receiveRTP(runContext, rtp, metadata, publisher.publish)
	}()
	if audioRTP != nil {
		go func() {
			if err := receiveAudioRTP(runContext, audioRTP, audio.broadcast); err != nil &&
				!errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) {
				log.Printf("audio receiver stopped: %v", err)
			}
		}()
	}
	streamError := make(chan error, 1)
	go func() {
		defer close(metadata)
		streamError <- receiveStreamEvents(streamEvents, clipboard.publish, func(value frameMetadata) error {
			select {
			case metadata <- value:
				return nil
			case <-runContext.Done():
				return runContext.Err()
			}
		}, func(payload []byte) {
			message, _ := json.Marshal(map[string]any{"type": "resize-applied", "request": binary.LittleEndian.Uint16(payload[0:2]), "width": binary.LittleEndian.Uint32(payload[4:8]), "height": binary.LittleEndian.Uint32(payload[8:12]), "scale": binary.LittleEndian.Uint16(payload[12:14]), "generation": binary.LittleEndian.Uint32(payload[16:20])})
			events.publish(message)
		})
	}()
	waitError := make(chan error, 1)
	go func() {
		waitError <- command.Wait()
	}()
	select {
	case err := <-parseError:
		cancelRun()
		_ = command.Cancel()
		<-waitError
		<-streamError
		return err
	case err := <-streamError:
		cancelRun()
		_ = command.Cancel()
		<-waitError
		_ = rtp.Close()
		<-parseError
		return err
	case err := <-waitError:
		_ = command.Cancel()
		cancelRun()
		_ = rtp.Close()
		if parseErr := <-parseError; parseErr != nil && !errors.Is(parseErr, net.ErrClosed) {
			return parseErr
		}
		if streamErr := <-streamError; streamErr != nil && !errors.Is(streamErr, io.EOF) {
			return streamErr
		}
		return err
	}
}

func receiveStreamEvents(reader io.Reader, emitClipboard func([]byte), emitMetadata func(frameMetadata) error, emitResize func([]byte)) error {
	var header [streamEventHeaderSize]byte
	for {
		if _, err := io.ReadFull(reader, header[:]); err != nil {
			return err
		}
		if header[0] != protocolVersion || header[2] != 0 || header[3] != 0 {
			return errors.New("invalid stream event header")
		}
		length := binary.LittleEndian.Uint32(header[4:8])
		if length > maximumClipboardBytes {
			return errors.New("stream event exceeds size limit")
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(reader, payload); err != nil {
			return err
		}
		switch header[1] {
		case streamClipboard:
			if !utf8.Valid(payload) {
				return errors.New("stream clipboard is not UTF-8")
			}
			emitClipboard(payload)
		case streamFrameMetadata:
			if len(payload) != 32 {
				return errors.New("invalid frame metadata")
			}
			metadata := frameMetadata{generation: binary.LittleEndian.Uint32(payload[0:4]), width: binary.LittleEndian.Uint16(payload[4:6]), height: binary.LittleEndian.Uint16(payload[6:8]), captureNanos: binary.LittleEndian.Uint64(payload[8:16]), sequence: binary.LittleEndian.Uint64(payload[16:24]), inputSequence: binary.LittleEndian.Uint32(payload[24:28]), fps: binary.LittleEndian.Uint32(payload[28:32])}
			if metadata.fps == 0 || metadata.fps > 240 {
				return errors.New("invalid frame metadata FPS")
			}
			if err := emitMetadata(metadata); err != nil {
				return err
			}
		case streamResizeApplied:
			if len(payload) != 20 {
				return errors.New("invalid resize event")
			}
			emitResize(payload)
		default:
			return errors.New("unknown stream event")
		}
	}
}

func listenLoopbackRTP() (*net.UDPConn, int, error) {
	for {
		connection, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, 0, err
		}
		if err := connection.SetReadBuffer(4 << 20); err != nil {
			_ = connection.Close()
			return nil, 0, err
		}
		port := connection.LocalAddr().(*net.UDPAddr).Port
		if port < math.MaxUint16 {
			return connection, port, nil
		}
		_ = connection.Close()
	}
}

type audioRTPTracker struct {
	have             bool
	ssrc             uint32
	sequence         uint64
	timestampTicks   uint64
	lastSeq          uint16
	lastTS           uint32
	generation       uint32
	clockBaseNanos   uint64
	windowMinBase    uint64
	windowStartNanos uint64
	lastCaptureNanos uint64
}

func (tracker *audioRTPTracker) consume(packet rtpPacket, receiveNanos uint64) (audioSample, bool) {
	if packet.payloadType != audioRTPPayloadType || len(packet.payload) > maximumAudioPacket {
		return audioSample{}, false
	}
	discontinuity := !tracker.have || packet.ssrc != tracker.ssrc
	if discontinuity {
		tracker.have = true
		tracker.ssrc = packet.ssrc
		tracker.sequence = 0
		tracker.timestampTicks = 0
		tracker.lastSeq = packet.sequence
		tracker.lastTS = packet.timestamp
		tracker.clockBaseNanos = 0
		tracker.windowMinBase = 0
		tracker.windowStartNanos = 0
		tracker.lastCaptureNanos = 0
		tracker.generation++
		if tracker.generation == 0 {
			tracker.generation = 1
		}
	} else {
		sequenceDelta := uint16(packet.sequence - tracker.lastSeq)
		if sequenceDelta == 0 || sequenceDelta > math.MaxInt16 {
			return audioSample{}, false
		}
		discontinuity = sequenceDelta != 1
		tracker.sequence += uint64(sequenceDelta)
		tracker.timestampTicks += uint64(packet.timestamp - tracker.lastTS)
		tracker.lastSeq = packet.sequence
		tracker.lastTS = packet.timestamp
	}
	mediaNanos := audioMediaNanos(tracker.timestampTicks)
	mediaAge := mediaNanos + uint64(audioFrameNanos)
	candidateBase := uint64(0)
	if receiveNanos > mediaAge {
		candidateBase = receiveNanos - mediaAge
	}
	if tracker.windowMinBase == 0 || candidateBase < tracker.windowMinBase {
		tracker.windowMinBase = candidateBase
	}
	if tracker.clockBaseNanos == 0 {
		tracker.clockBaseNanos = candidateBase
	} else if candidateBase < tracker.clockBaseNanos {
		tracker.clockBaseNanos -= min(
			tracker.clockBaseNanos-candidateBase,
			uint64(audioClockCorrection),
		)
	}
	if mediaNanos-tracker.windowStartNanos >= uint64(audioClockWindow) {
		if tracker.windowMinBase > tracker.clockBaseNanos {
			tracker.clockBaseNanos += min(
				tracker.windowMinBase-tracker.clockBaseNanos,
				uint64(audioClockCorrection),
			)
		}
		tracker.windowMinBase = candidateBase
		tracker.windowStartNanos = mediaNanos
	}
	captureNanos := tracker.clockBaseNanos + mediaNanos
	if captureNanos <= tracker.lastCaptureNanos {
		captureNanos = tracker.lastCaptureNanos + 1
	}
	tracker.lastCaptureNanos = captureNanos
	return audioSample{
		data:          append([]byte(nil), packet.payload...),
		discontinuity: discontinuity,
		sequence:      tracker.sequence,
		timestamp:     captureNanos / uint64(time.Microsecond),
		generation:    tracker.generation,
	}, true
}

func audioMediaNanos(timestampTicks uint64) uint64 {
	return timestampTicks/audioSampleRate*uint64(time.Second) +
		timestampTicks%audioSampleRate*uint64(time.Second)/audioSampleRate
}

func monotonicNanos() (uint64, error) {
	var timestamp unix.Timespec
	if err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &timestamp); err != nil {
		return 0, err
	}
	return uint64(timestamp.Sec)*uint64(time.Second) + uint64(timestamp.Nsec), nil
}

func receiveAudioRTP(ctx context.Context, connection *net.UDPConn, emit func(audioSample)) error {
	buffer := make([]byte, 64<<10)
	var tracker audioRTPTracker
	for {
		if err := connection.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
			return err
		}
		length, source, err := connection.ReadFromUDPAddrPort(buffer)
		if err != nil {
			if netError, ok := err.(net.Error); ok && netError.Timeout() {
				// FFmpeg emits Opus continuously, including for a silent sink. A
				// full second without RTP therefore marks an encoder interruption;
				// force the first packet from its replacement to reset browser state.
				tracker.have = false
				select {
				case <-ctx.Done():
					return ctx.Err()
				default:
					continue
				}
			}
			return err
		}
		if !source.Addr().IsLoopback() {
			continue
		}
		packet, err := decodeRTPPacket(buffer[:length])
		if err != nil {
			continue
		}
		receiveNanos, err := monotonicNanos()
		if err != nil {
			return err
		}
		if sample, ok := tracker.consume(packet, receiveNanos); ok {
			emit(sample)
		}
	}
}

func receiveRTP(ctx context.Context, connection *net.UDPConn, metadata <-chan frameMetadata, emit func(sample) error) error {
	buffer := make([]byte, 64<<10)
	var assembler rtpH264Assembler
	var lastTimestamp uint32
	var lastSSRC uint32
	var haveTimestamp bool
	var lastGeneration uint32
	var lastFPS uint32
	for {
		length, source, err := connection.ReadFromUDPAddrPort(buffer)
		if err != nil {
			return err
		}
		if !source.Addr().IsLoopback() {
			continue
		}
		packet, err := decodeRTPPacket(buffer[:length])
		if err != nil {
			continue
		}
		if packet.payloadType != rtpPayloadType {
			continue
		}
		unit, complete, assembleErr := assembler.consume(buffer[:length])
		if !packet.marker {
			if assembleErr != nil {
				continue
			}
			continue
		}
		consumeCount := 1
		if haveTimestamp && packet.ssrc == lastSSRC {
			consumeCount = metadataCountForTimestampGap(
				packet.timestamp-lastTimestamp,
				lastFPS,
			)
		}
		restarted := haveTimestamp && packet.ssrc != lastSSRC
		lastTimestamp, lastSSRC, haveTimestamp = packet.timestamp, packet.ssrc, true
		meta, err := takeFrameMetadata(ctx, metadata, consumeCount, restarted, lastGeneration)
		if err != nil {
			return err
		}
		lastFPS = meta.fps
		if assembleErr != nil || !complete {
			continue
		}
		discontinuity := unit.discontinuity || consumeCount > 1 || lastGeneration != 0 && meta.generation != lastGeneration
		lastGeneration = meta.generation
		if err := emit(sample{
			data:          unit.data,
			key:           unit.key,
			discontinuity: discontinuity,
			sequence:      meta.sequence,
			timestamp:     meta.captureNanos / 1000,
			generation:    meta.generation, width: meta.width, height: meta.height,
			captureNanos: meta.captureNanos, inputSequence: meta.inputSequence,
		}); err != nil {
			return err
		}
	}
}

func takeFrameMetadata(
	ctx context.Context,
	metadata <-chan frameMetadata,
	consumeCount int,
	restarted bool,
	lastGeneration uint32,
) (frameMetadata, error) {
	var meta frameMetadata
	for {
		select {
		case value, ok := <-metadata:
			if !ok {
				return frameMetadata{}, io.EOF
			}
			meta = value
		case <-ctx.Done():
			return frameMetadata{}, ctx.Err()
		}
		if restarted && lastGeneration != 0 {
			if meta.generation != lastGeneration {
				return meta, nil
			}
			continue
		}
		consumeCount--
		if consumeCount == 0 {
			return meta, nil
		}
	}
}

func metadataCountForTimestampGap(delta uint32, fps uint32) int {
	if delta == 0 {
		return 1
	}
	if fps == 0 {
		fps = 30
	}
	// RTP's H.264 clock is 90 kHz. Infer entirely absent AUs, but cap
	// hostile or restart-sized gaps to the metadata channel bound.
	return min(120, max(1, int((uint64(delta)*uint64(fps)+45_000)/90_000)))
}

type h264AccessUnit struct {
	data          []byte
	key           bool
	discontinuity bool
}

type rtpH264Assembler struct {
	data          []byte
	key           bool
	fuActive      bool
	haveTimestamp bool
	timestamp     uint32
	haveSequence  bool
	nextSequence  uint16
	haveSSRC      bool
	ssrc          uint32
	recovering    bool
}

type rtpPacket struct {
	marker      bool
	sequence    uint16
	timestamp   uint32
	ssrc        uint32
	payloadType byte
	payload     []byte
}

func (assembler *rtpH264Assembler) consume(datagram []byte) (h264AccessUnit, bool, error) {
	packet, err := decodeRTPPacket(datagram)
	if err != nil {
		return h264AccessUnit{}, false, err
	}
	if packet.payloadType != rtpPayloadType {
		return h264AccessUnit{}, false, nil
	}
	if assembler.haveSSRC && assembler.ssrc != packet.ssrc {
		assembler.clearAccessUnit()
		assembler.haveSequence = false
		assembler.recovering = true
	}
	assembler.ssrc = packet.ssrc
	assembler.haveSSRC = true
	if assembler.haveSequence && packet.sequence != assembler.nextSequence {
		assembler.clearAccessUnit()
		assembler.recovering = true
	}
	assembler.nextSequence = packet.sequence + 1
	assembler.haveSequence = true
	if assembler.haveTimestamp && assembler.timestamp != packet.timestamp {
		assembler.clearAccessUnit()
		assembler.recovering = true
	}
	if !assembler.haveTimestamp {
		assembler.timestamp = packet.timestamp
		assembler.haveTimestamp = true
	}
	if err := assembler.appendPayload(packet.payload); err != nil {
		assembler.clearAccessUnit()
		assembler.recovering = true
		return h264AccessUnit{}, false, err
	}
	if !packet.marker {
		return h264AccessUnit{}, false, nil
	}
	if assembler.fuActive {
		assembler.clearAccessUnit()
		assembler.recovering = true
		return h264AccessUnit{}, false, errors.New("RTP marker ended an incomplete H.264 fragment")
	}
	unit := h264AccessUnit{
		data: append([]byte(nil), assembler.data...),
		key:  assembler.key,
	}
	assembler.clearAccessUnit()
	if len(unit.data) == 0 {
		return h264AccessUnit{}, false, nil
	}
	if assembler.recovering {
		if !unit.key {
			return h264AccessUnit{}, false, nil
		}
		unit.discontinuity = true
		assembler.recovering = false
	}
	return unit, true, nil
}

func (assembler *rtpH264Assembler) appendPayload(payload []byte) error {
	if len(payload) == 0 {
		return errors.New("empty H.264 RTP payload")
	}
	typeID := payload[0] & 0x1f
	switch {
	case typeID >= 1 && typeID <= 23:
		return assembler.appendNAL(payload)
	case typeID == 24:
		payload = payload[1:]
		for len(payload) > 0 {
			if len(payload) < 2 {
				return errors.New("truncated H.264 STAP-A length")
			}
			length := int(binary.BigEndian.Uint16(payload[:2]))
			payload = payload[2:]
			if length == 0 || length > len(payload) {
				return errors.New("invalid H.264 STAP-A NAL length")
			}
			if err := assembler.appendNAL(payload[:length]); err != nil {
				return err
			}
			payload = payload[length:]
		}
		return nil
	case typeID == 28:
		if len(payload) < 2 {
			return errors.New("truncated H.264 FU-A payload")
		}
		start := payload[1]&0x80 != 0
		end := payload[1]&0x40 != 0
		fragmentType := payload[1] & 0x1f
		if fragmentType == 0 || start && assembler.fuActive || !start && !assembler.fuActive {
			return errors.New("invalid H.264 FU-A sequence")
		}
		if start {
			header := payload[0]&0xe0 | fragmentType
			if err := assembler.appendNAL([]byte{header}); err != nil {
				return err
			}
			assembler.fuActive = true
		}
		if err := assembler.appendBytes(payload[2:]); err != nil {
			return err
		}
		if fragmentType == 5 {
			assembler.key = true
		}
		if end {
			assembler.fuActive = false
		}
		return nil
	default:
		return fmt.Errorf("unsupported H.264 RTP packetization type %d", typeID)
	}
}

func (assembler *rtpH264Assembler) appendNAL(nal []byte) error {
	if len(nal) == 0 {
		return errors.New("empty H.264 NAL")
	}
	if nal[0]&0x1f == 5 {
		assembler.key = true
	}
	if err := assembler.appendBytes([]byte{0, 0, 0, 1}); err != nil {
		return err
	}
	return assembler.appendBytes(nal)
}

func (assembler *rtpH264Assembler) appendBytes(value []byte) error {
	if len(assembler.data)+len(value) > maximumAccessUnitSize {
		return errors.New("H.264 access unit exceeds size limit")
	}
	assembler.data = append(assembler.data, value...)
	return nil
}

func (assembler *rtpH264Assembler) clearAccessUnit() {
	assembler.data = assembler.data[:0]
	assembler.key = false
	assembler.fuActive = false
	assembler.haveTimestamp = false
}

func decodeRTPPacket(datagram []byte) (rtpPacket, error) {
	if len(datagram) < 12 || datagram[0]>>6 != 2 {
		return rtpPacket{}, errors.New("invalid RTP header")
	}
	headerLength := 12 + int(datagram[0]&0x0f)*4
	if headerLength > len(datagram) {
		return rtpPacket{}, errors.New("truncated RTP CSRC list")
	}
	if datagram[0]&0x10 != 0 {
		if headerLength+4 > len(datagram) {
			return rtpPacket{}, errors.New("truncated RTP extension")
		}
		extensionLength := int(binary.BigEndian.Uint16(datagram[headerLength+2:headerLength+4])) * 4
		headerLength += 4 + extensionLength
		if headerLength > len(datagram) {
			return rtpPacket{}, errors.New("truncated RTP extension payload")
		}
	}
	payloadEnd := len(datagram)
	if datagram[0]&0x20 != 0 {
		padding := int(datagram[len(datagram)-1])
		if padding == 0 || padding > payloadEnd-headerLength {
			return rtpPacket{}, errors.New("invalid RTP padding")
		}
		payloadEnd -= padding
	}
	if headerLength == payloadEnd {
		return rtpPacket{}, errors.New("empty RTP payload")
	}
	return rtpPacket{
		marker:      datagram[1]&0x80 != 0,
		payloadType: datagram[1] & 0x7f,
		sequence:    binary.BigEndian.Uint16(datagram[2:4]),
		timestamp:   binary.BigEndian.Uint32(datagram[4:8]),
		ssrc:        binary.BigEndian.Uint32(datagram[8:12]),
		payload:     datagram[headerLength:payloadEnd],
	}, nil
}

func (s sample) String() string {
	return fmt.Sprintf("sample{sequence:%d key:%t bytes:%d}", s.sequence, s.key, len(s.data))
}
