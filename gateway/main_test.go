package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestParseAllowedOrigin(t *testing.T) {
	origin, err := parseAllowedOrigin("https://stream.example.test/session/")
	if err != nil {
		t.Fatal(err)
	}
	if origin != "https://stream.example.test" {
		t.Fatalf("origin = %q", origin)
	}
	if _, err := parseAllowedOrigin("stream.example.test"); err == nil {
		t.Fatal("relative public URL should be rejected")
	}
}

func TestRTPAssemblerEmitsAccessUnitAtMarkerWithoutNextFrame(t *testing.T) {
	var assembler rtpH264Assembler
	const timestamp = 90_000
	const ssrc = 7
	stap := []byte{24, 0, 2, 0x67, 1, 0, 2, 0x68, 2}
	if _, complete, err := assembler.consume(makeRTPPacket(10, timestamp, ssrc, false, stap)); err != nil || complete {
		t.Fatalf("SPS/PPS packet: complete=%t err=%v", complete, err)
	}
	if _, complete, err := assembler.consume(makeRTPPacket(
		11,
		timestamp,
		ssrc,
		false,
		[]byte{0x7c, 0x85, 0x11, 0x22},
	)); err != nil || complete {
		t.Fatalf("IDR start packet: complete=%t err=%v", complete, err)
	}
	unit, complete, err := assembler.consume(makeRTPPacket(
		12,
		timestamp,
		ssrc,
		true,
		[]byte{0x7c, 0x45, 0x33, 0x44},
	))
	if err != nil {
		t.Fatal(err)
	}
	if !complete || !unit.key {
		t.Fatalf("marker packet produced %+v, complete=%t", unit, complete)
	}
	wantIDR := []byte{0, 0, 0, 1, 0x65, 0x11, 0x22, 0x33, 0x44}
	if !bytes.Contains(unit.data, wantIDR) {
		t.Fatalf("access unit does not contain reconstructed IDR: %x", unit.data)
	}
}

func TestEncodeVideoMessage(t *testing.T) {
	message := encodeVideoMessage(sample{
		data:          []byte{1, 2, 3},
		key:           true,
		discontinuity: true,
		sequence:      17,
		timestamp:     99,
	})
	if len(message) != videoHeaderSize+3 {
		t.Fatalf("message length = %d", len(message))
	}
	if message[0] != protocolVersion || message[1] != videoMessage || message[2] != 3 {
		t.Fatalf("unexpected header: %v", message[:4])
	}
}

func TestEncodeAudioMessage(t *testing.T) {
	message := encodeAudioMessage(audioSample{
		data:          []byte{1, 2, 3},
		discontinuity: true,
		sequence:      17,
		timestamp:     20_000,
		generation:    4,
	})
	if len(message) != audioHeaderSize+3 {
		t.Fatalf("message length = %d", len(message))
	}
	if message[0] != protocolVersion || message[1] != audioMessage || message[2] != 1 ||
		binary.LittleEndian.Uint64(message[4:12]) != 17 ||
		binary.LittleEndian.Uint64(message[12:20]) != 20_000 ||
		binary.LittleEndian.Uint32(message[20:24]) != 4 {
		t.Fatalf("unexpected audio header: %v", message[:audioHeaderSize])
	}
}

func TestAudioRTPTrackerExtendsClockAndMarksLoss(t *testing.T) {
	var tracker audioRTPTracker
	packet := func(sequence uint16, timestamp, ssrc uint32) rtpPacket {
		return rtpPacket{
			payloadType: audioRTPPayloadType,
			sequence:    sequence,
			timestamp:   timestamp,
			ssrc:        ssrc,
			payload:     []byte{1, 2, 3},
		}
	}
	first, ok := tracker.consume(packet(math.MaxUint16, math.MaxUint32-959, 7), uint64(time.Second))
	if !ok || !first.discontinuity || first.sequence != 0 || first.timestamp != 980_000 || first.generation != 1 {
		t.Fatalf("unexpected first packet: %+v, ok=%t", first, ok)
	}
	wrapped, ok := tracker.consume(packet(0, 0, 7), uint64(time.Second+20*time.Millisecond))
	if !ok || wrapped.discontinuity || wrapped.sequence != 1 || wrapped.timestamp != 1_000_000 {
		t.Fatalf("unexpected wrapped packet: %+v, ok=%t", wrapped, ok)
	}
	lost, ok := tracker.consume(packet(2, 1920, 7), uint64(time.Second+60*time.Millisecond))
	if !ok || !lost.discontinuity || lost.sequence != 3 || lost.timestamp != 1_040_000 {
		t.Fatalf("unexpected packet after loss: %+v, ok=%t", lost, ok)
	}
	restarted, ok := tracker.consume(packet(40, 90_000, 8), 2*uint64(time.Second))
	if !ok || !restarted.discontinuity || restarted.sequence != 0 || restarted.timestamp != 1_980_000 || restarted.generation != 2 {
		t.Fatalf("unexpected restarted stream: %+v, ok=%t", restarted, ok)
	}
}

func TestAudioRTPTrackerCorrectsClockWithoutRegressingTimestamps(t *testing.T) {
	var tracker audioRTPTracker
	first, ok := tracker.consume(rtpPacket{
		payloadType: audioRTPPayloadType,
		sequence:    1,
		timestamp:   1,
		ssrc:        7,
		payload:     []byte{1},
	}, uint64(time.Second))
	if !ok {
		t.Fatal("first packet rejected")
	}
	second, ok := tracker.consume(rtpPacket{
		payloadType: audioRTPPayloadType,
		sequence:    2,
		timestamp:   961,
		ssrc:        7,
		payload:     []byte{2},
	}, uint64(time.Second+19*time.Millisecond))
	if !ok || first.timestamp != 980_000 || second.timestamp != 999_000 || second.timestamp <= first.timestamp {
		t.Fatalf("unexpected corrected clock: first=%+v second=%+v ok=%t", first, second, ok)
	}
}

func TestAudioRTPTrackerFollowsSlowClockDrift(t *testing.T) {
	var tracker audioRTPTracker
	var latest audioSample
	for index := uint64(0); index <= 500; index++ {
		media := index * uint64(audioFrameNanos)
		receive := uint64(time.Second) + media
		if index > 0 {
			receive += 5 * uint64(time.Millisecond)
		}
		var ok bool
		latest, ok = tracker.consume(rtpPacket{
			payloadType: audioRTPPayloadType,
			sequence:    uint16(index),
			timestamp:   uint32(index * 960),
			ssrc:        7,
			payload:     []byte{1},
		}, receive)
		if !ok {
			t.Fatalf("packet %d rejected", index)
		}
	}
	if latest.timestamp != 10_981_000 {
		t.Fatalf("timestamp after upward correction = %d, want 10981000", latest.timestamp)
	}
}

func TestAudioMediaNanosDoesNotOverflowAfterFiveDays(t *testing.T) {
	ticks := uint64(5*24*time.Hour/time.Second) * audioSampleRate
	if got, want := audioMediaNanos(ticks), uint64(5*24*time.Hour); got != want {
		t.Fatalf("audioMediaNanos() = %d, want %d", got, want)
	}
}

func TestAudioHubDropsQueuedLatencyAndMarksDiscontinuity(t *testing.T) {
	hub := newAudioHub()
	subscriber := hub.subscribe()
	defer hub.unsubscribe(subscriber)
	for sequence := uint64(0); sequence <= uint64(cap(subscriber.packets)); sequence++ {
		hub.broadcast(audioSample{sequence: sequence})
	}
	if len(subscriber.packets) != 1 {
		t.Fatalf("queued packets after overflow = %d, want 1", len(subscriber.packets))
	}
	packet := <-subscriber.packets
	if !packet.discontinuity || packet.sequence != uint64(cap(subscriber.packets)) {
		t.Fatalf("unexpected recovery packet: %+v", packet)
	}
}

func TestClipboardProcessFraming(t *testing.T) {
	text := []byte("hello, 🐧")
	input := encodeClipboardInput(text)
	if len(input) != controlSize+len(text) || input[0] != protocolVersion ||
		input[1] != controlClipboard {
		t.Fatalf("unexpected clipboard input header: %v", input[:controlSize])
	}
	if length := binary.LittleEndian.Uint32(input[4:8]); length != uint32(len(text)) {
		t.Fatalf("clipboard input length = %d, want %d", length, len(text))
	}
	if !bytes.Equal(input[controlSize:], text) {
		t.Fatalf("clipboard input = %q, want %q", input[controlSize:], text)
	}

	var stream bytes.Buffer
	stream.Write([]byte{protocolVersion, streamClipboard, 0, 0})
	if err := binary.Write(&stream, binary.LittleEndian, uint32(len(text))); err != nil {
		t.Fatal(err)
	}
	stream.Write(text)
	var received []byte
	err := receiveStreamEvents(&stream, func(value []byte) {
		received = append([]byte(nil), value...)
	}, func(frameMetadata) error { return nil }, func([]byte) {})
	if !errors.Is(err, io.EOF) {
		t.Fatalf("receiveStreamEvents() error = %v, want EOF", err)
	}
	if !bytes.Equal(received, text) {
		t.Fatalf("stream clipboard = %q, want %q", received, text)
	}
}

func TestClipboardBridgeKeepsLatestForController(t *testing.T) {
	var bridge clipboardBridge
	bridge.publish([]byte("first"))
	bridge.publish([]byte("latest"))
	updates := make(chan []byte, 1)
	bridge.attach(updates)
	defer bridge.detach(updates)

	var message struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(<-updates, &message); err != nil {
		t.Fatal(err)
	}
	if message.Type != "clipboard" || message.Text != "latest" {
		t.Fatalf("unexpected clipboard event: %+v", message)
	}
}

func TestDecodeClipboardRequestRejectsOversizedText(t *testing.T) {
	text, err := decodeClipboardRequest([]byte(`{"type":"clipboard-write","text":"hello"}`))
	if err != nil || string(text) != "hello" {
		t.Fatalf("decoded clipboard = %q, error = %v", text, err)
	}
	oversized, err := json.Marshal(map[string]string{
		"type": "clipboard-write",
		"text": strings.Repeat("x", maximumClipboardBytes+1),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeClipboardRequest(oversized); err == nil {
		t.Fatal("oversized clipboard should be rejected")
	}
}

func TestHubResynchronizesSlowSubscriberWithoutDisconnecting(t *testing.T) {
	hub := newHub()
	subscriber, _ := hub.subscribe()
	defer hub.unsubscribe(subscriber)

	for sequence := uint64(0); sequence <= uint64(cap(subscriber.frames)); sequence++ {
		hub.broadcast(sample{sequence: sequence})
	}
	if len(subscriber.frames) != 0 {
		t.Fatalf("queued frames after overflow = %d, want 0", len(subscriber.frames))
	}

	hub.broadcast(sample{sequence: 10})
	if len(subscriber.frames) != 0 {
		t.Fatal("delta frame queued while waiting for recovery keyframe")
	}
	hub.broadcast(sample{key: true, sequence: 11})
	recovered := <-subscriber.frames
	if !recovered.discontinuity || !recovered.key || recovered.sequence != 11 {
		t.Fatalf("unexpected recovery frame: %+v", recovered)
	}

	hub.broadcast(sample{sequence: 12})
	continued := <-subscriber.frames
	if continued.discontinuity || continued.sequence != 12 {
		t.Fatalf("unexpected frame after recovery: %+v", continued)
	}
}

func TestHubBootstrapsIdleSubscriberFromLatestGOP(t *testing.T) {
	hub := newHub()
	hub.broadcast(sample{key: true, sequence: 20, data: []byte{1}})
	hub.broadcast(sample{sequence: 21, data: []byte{2}})

	subscriber, bootstrap := hub.subscribe()
	defer hub.unsubscribe(subscriber)
	if len(bootstrap) != 2 || !bootstrap[0].key ||
		bootstrap[0].sequence != 20 || bootstrap[1].sequence != 21 {
		t.Fatalf("unexpected bootstrap GOP: %+v", bootstrap)
	}
}

func TestVideoPublisherTracksCachedKeyframeReadiness(t *testing.T) {
	hub := newHub()
	writer := &keyframeAcknowledgementWriter{hub: hub}
	input := &inputBridge{}
	input.attach(writer)
	defer input.detach()
	publisher := &videoPublisher{hub: hub, input: input}

	for _, frame := range []sample{
		{generation: 4},
		{key: true, generation: 4, sequence: 1},
		{key: true, generation: 4, sequence: 2},
		{discontinuity: true, generation: 4, sequence: 3},
		{key: true, generation: 4, sequence: 4},
		{key: true, generation: 5, sequence: 5},
	} {
		if err := publisher.publish(frame); err != nil {
			t.Fatal(err)
		}
	}
	if len(writer.records) != 4 {
		t.Fatalf("readiness transitions = %d, want 4", len(writer.records))
	}
	for index, expected := range []struct {
		generation uint32
		ready      byte
	}{{4, 1}, {4, 0}, {4, 1}, {5, 1}} {
		record := writer.records[index]
		if len(record) != controlSize || record[0] != protocolVersion ||
			record[1] != controlKeyframeReady ||
			record[2] != expected.ready ||
			binary.LittleEndian.Uint32(record[4:8]) != expected.generation {
			t.Fatalf("readiness transition %d = %v", index, record)
		}
	}
}

type keyframeAcknowledgementWriter struct {
	hub     *hub
	records [][]byte
}

func (writer *keyframeAcknowledgementWriter) Write(record []byte) (int, error) {
	writer.hub.mu.Lock()
	cached := len(writer.hub.latestGOP) > 0 && writer.hub.latestGOP[0].key &&
		writer.hub.latestGOP[0].generation == binary.LittleEndian.Uint32(record[4:8])
	writer.hub.mu.Unlock()
	if cached != (record[2] == 1) {
		return 0, errors.New("keyframe readiness disagrees with GOP cache")
	}
	writer.records = append(writer.records, append([]byte(nil), record...))
	return len(record), nil
}

func (writer *keyframeAcknowledgementWriter) Close() error { return nil }

func TestQualityPolicyIgnoresDamageDrivenIdle(t *testing.T) {
	now := time.Now()
	policy := qualityPolicy{bitrate: 6000, fps: 60, scale: 100, maxBitrate: 6000, maxFPS: 60, last: now.Add(-time.Hour)}
	for range 20 {
		if policy.update(0, 0, 0, 20, false, now) {
			t.Fatal("idle feedback changed quality")
		}
	}
}

func TestQualityPolicyDownshiftsAndRecoversWithinStartupCeilings(t *testing.T) {
	now := time.Now()
	policy := qualityPolicy{bitrate: 6000, fps: 60, scale: 100, maxBitrate: 6000, maxFPS: 60, last: now.Add(-time.Hour)}
	policy.update(6, 0, 60, 20, true, now)
	if !policy.update(6, 0, 60, 20, true, now) || policy.bitrate >= 6000 {
		t.Fatalf("sustained queue did not downshift: %+v", policy)
	}
	if policy.fps != 60 || policy.scale != 100 {
		t.Fatalf("first downshift sacrificed frame rate or resolution: %+v", policy)
	}
	for index := 0; index < 8; index++ {
		policy.update(0, 0, 60, 20, true, now.Add(6*time.Second))
	}
	if policy.bitrate > policy.maxBitrate || policy.fps > policy.maxFPS || policy.scale > 100 {
		t.Fatalf("recovery exceeded startup ceiling: %+v", policy)
	}
}

func TestQualityPolicyDoesNotTreatPresentationDropsAsCongestion(t *testing.T) {
	now := time.Now()
	policy := qualityPolicy{bitrate: 12000, fps: 30, scale: 100, maxBitrate: 12000, maxFPS: 30, last: now.Add(-time.Hour)}
	for range 10 {
		if policy.update(0, 30, 30, 20, true, now) {
			t.Fatalf("presentation drops changed quality: %+v", policy)
		}
	}
}

func TestMetadataCountForTimestampGapAccountsForLostAccessUnits(t *testing.T) {
	if count := metadataCountForTimestampGap(3_000, 30); count != 1 {
		t.Fatalf("one 30 FPS timestamp step consumed %d metadata records", count)
	}
	if count := metadataCountForTimestampGap(9_000, 30); count != 3 {
		t.Fatalf("three 30 FPS timestamp steps consumed %d metadata records", count)
	}
	if count := metadataCountForTimestampGap(math.MaxUint32, 60); count != 120 {
		t.Fatalf("large timestamp gap consumed %d metadata records, want bounded 120", count)
	}
}

func TestTakeFrameMetadataDiscardsOldGenerationAfterEncoderRestart(t *testing.T) {
	metadata := make(chan frameMetadata, 3)
	metadata <- frameMetadata{generation: 5, sequence: 10}
	metadata <- frameMetadata{generation: 5, sequence: 11}
	metadata <- frameMetadata{generation: 6, sequence: 12}

	got, err := takeFrameMetadata(context.Background(), metadata, 1, true, 5)
	if err != nil {
		t.Fatal(err)
	}
	if got.generation != 6 || got.sequence != 12 {
		t.Fatalf("metadata after restart = %+v, want generation 6 sequence 12", got)
	}
}

func TestTakeFrameMetadataPreservesTimestampGapConsumption(t *testing.T) {
	metadata := make(chan frameMetadata, 3)
	metadata <- frameMetadata{generation: 5, sequence: 10}
	metadata <- frameMetadata{generation: 5, sequence: 11}
	metadata <- frameMetadata{generation: 5, sequence: 12}

	got, err := takeFrameMetadata(context.Background(), metadata, 3, false, 5)
	if err != nil {
		t.Fatal(err)
	}
	if got.sequence != 12 {
		t.Fatalf("metadata after timestamp gap = %+v, want sequence 12", got)
	}
}

func TestValidControlRecord(t *testing.T) {
	repeatedKey := makeControlRecord(controlKeyboardKey, true, 30, 0, 0)
	repeatedKey[2] = 2
	repeatedPointer := makeControlRecord(controlPointerButton, true, 0x110, 0, 0)
	repeatedPointer[2] = 2
	tests := []struct {
		name   string
		record []byte
		valid  bool
	}{
		{"pointer motion", makeControlRecord(controlPointerMotion, false, 65_535, 32_768, 0), true},
		{"pointer button", makeControlRecord(controlPointerButton, true, 0x111, 0, 0), true},
		{"pointer scroll", makeControlRecord(controlPointerScroll, false, math.Float32bits(-14.5), math.Float32bits(120), 0), true},
		{"keyboard key", makeControlRecord(controlKeyboardKey, true, 30, 0, 0), true},
		{"repeated keyboard key", repeatedKey, true},
		{"release all", releaseAllRecord(), true},
		{"wrong size", []byte{1, controlReleaseAll}, false},
		{"wrong version", makeControlRecord(controlReleaseAll, false, 0, 0, 0), false},
		{"pointer out of range", makeControlRecord(controlPointerMotion, false, 65_536, 0, 0), false},
		{"unknown button", makeControlRecord(controlPointerButton, true, 0x115, 0, 0), false},
		{"repeated pointer button", repeatedPointer, false},
		{"nan scroll", makeControlRecord(controlPointerScroll, false, math.Float32bits(float32(math.NaN())), 0, 0), false},
		{"zero key", makeControlRecord(controlKeyboardKey, true, 0, 0, 0), false},
		{"release with flag", makeControlRecord(controlReleaseAll, true, 0, 0, 0), false},
		{"private keyframe acknowledgement", encodeKeyframeReadiness(7, true), false},
	}
	tests[7].record[0] = 1
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := validControlRecord(test.record); got != test.valid {
				t.Fatalf("validControlRecord() = %t, want %t", got, test.valid)
			}
		})
	}
}

func TestValidResizeControlRecord(t *testing.T) {
	tests := []struct {
		name   string
		record []byte
		valid  bool
	}{
		{"minimum", makeControlRecord(controlResize, false, 320, 180, 120), true},
		{"tall retina viewport", makeControlRecord(controlResize, false, 1696, 2176, 264), true},
		{"maximum", makeControlRecord(controlResize, false, 6000, 6000, 480), true},
		{"typical fractional scale", makeControlRecord(controlResize, false, 1920, 1080, 150), true},
		{"state set", makeControlRecord(controlResize, true, 1280, 720, 120), false},
		{"odd width", makeControlRecord(controlResize, false, 1279, 720, 120), false},
		{"odd height", makeControlRecord(controlResize, false, 1280, 719, 120), false},
		{"width below minimum", makeControlRecord(controlResize, false, 318, 720, 120), false},
		{"width above maximum", makeControlRecord(controlResize, false, 6002, 720, 120), false},
		{"height below minimum", makeControlRecord(controlResize, false, 1280, 178, 120), false},
		{"height above maximum", makeControlRecord(controlResize, false, 1280, 6002, 120), false},
		{"scale below minimum", makeControlRecord(controlResize, false, 1280, 720, 119), false},
		{"scale above maximum", makeControlRecord(controlResize, false, 1280, 720, 481), false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := validControlRecord(test.record); got != test.valid {
				t.Fatalf("validControlRecord() = %t, want %t", got, test.valid)
			}
		})
	}
}

func TestFixedResizeRecord(t *testing.T) {
	original := makeControlRecord(controlResize, false, 1920, 1080, 150)
	fixed := fixedResizeRecord(original, 1280, 720)
	if width := binary.LittleEndian.Uint32(fixed[4:8]); width != 1280 {
		t.Fatalf("width = %d, want 1280", width)
	}
	if height := binary.LittleEndian.Uint32(fixed[8:12]); height != 720 {
		t.Fatalf("height = %d, want 720", height)
	}
	if packed := binary.LittleEndian.Uint32(fixed[12:16]); packed != 1<<16|120 {
		t.Fatalf("packed request = %#x, want %#x", packed, 1<<16|120)
	}
	if width := binary.LittleEndian.Uint32(original[4:8]); width != 1920 {
		t.Fatalf("original width was mutated to %d", width)
	}
}

func TestGatewayAllowsOneController(t *testing.T) {
	gateway := &gateway{}
	if !gateway.claimController() {
		t.Fatal("first controller should be accepted")
	}
	if gateway.claimController() {
		t.Fatal("second controller should be rejected")
	}
	gateway.releaseController()
	if !gateway.claimController() {
		t.Fatal("controller should be accepted after the first disconnects")
	}
}

func TestControlConnectionsHandOffLeaseWithoutReconnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	input := &inputBridge{}
	input.attach(discardWriteCloser{})
	defer input.detach()
	gateway := &gateway{input: input, clipboard: &clipboardBridge{}}
	server := httptest.NewServer(http.HandlerFunc(gateway.control))
	defer server.Close()
	url := "ws" + strings.TrimPrefix(server.URL, "http")
	first, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer first.CloseNow()
	second, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer second.CloseNow()

	writeLeaseCommand(t, ctx, first, controlAcquire)
	expectControlState(t, ctx, first, "active")
	writeLeaseCommand(t, ctx, second, controlAcquire)
	expectControlState(t, ctx, second, "busy")
	writeLeaseCommand(t, ctx, first, controlRelease)
	expectControlState(t, ctx, first, "ready")
	writeLeaseCommand(t, ctx, second, controlAcquire)
	expectControlState(t, ctx, second, "active")
}

type discardWriteCloser struct{}

func (discardWriteCloser) Write(value []byte) (int, error) {
	return len(value), nil
}

func (discardWriteCloser) Close() error {
	return nil
}

func writeLeaseCommand(t *testing.T, ctx context.Context, connection *websocket.Conn, command string) {
	t.Helper()
	if err := connection.Write(ctx, websocket.MessageText, []byte(command)); err != nil {
		t.Fatal(err)
	}
}

func expectControlState(t *testing.T, ctx context.Context, connection *websocket.Conn, expected string) {
	t.Helper()
	messageType, message, err := connection.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if messageType != websocket.MessageText {
		t.Fatalf("message type = %v, want text", messageType)
	}
	var state struct {
		Type  string `json:"type"`
		State string `json:"state"`
	}
	if err := json.Unmarshal(message, &state); err != nil {
		t.Fatal(err)
	}
	if state.Type != "control-state" || state.State != expected {
		t.Fatalf("control state = %+v, want %q", state, expected)
	}
}

func makeControlRecord(command byte, pressed bool, a, b, c uint32) []byte {
	if command == controlResize {
		c |= 1 << 16
	} else if command != controlReleaseAll && c == 0 {
		c = 1
	}
	record := make([]byte, controlSize)
	record[0] = protocolVersion
	record[1] = command
	if pressed {
		record[2] = 1
	}
	binary.LittleEndian.PutUint32(record[4:8], a)
	binary.LittleEndian.PutUint32(record[8:12], b)
	binary.LittleEndian.PutUint32(record[12:16], c)
	return record
}

func makeRTPPacket(sequence uint16, timestamp, ssrc uint32, marker bool, payload []byte) []byte {
	packet := make([]byte, 12+len(payload))
	packet[0] = 2 << 6
	packet[1] = rtpPayloadType
	if marker {
		packet[1] |= 0x80
	}
	binary.BigEndian.PutUint16(packet[2:4], sequence)
	binary.BigEndian.PutUint32(packet[4:8], timestamp)
	binary.BigEndian.PutUint32(packet[8:12], ssrc)
	copy(packet[12:], payload)
	return packet
}
