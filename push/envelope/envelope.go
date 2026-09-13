package envelope

import (
	"crypto/hpke"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

const (
	Version = 1

	// Info binds the HPKE context to this protocol version.
	Info = "rootshell-push/v1"

	// MaxHeaderBytes keeps the sealed header inside the 4 KiB APNs budget
	// alongside aps, the base64url encapsulation and the event id.
	MaxHeaderBytes = 1600
	MaxEventIDLen  = 64
	MaxTitleLen    = 120
	MaxBodyLen     = 600
)

var (
	ErrHeaderTooLarge = errors.New("envelope: header exceeds MaxHeaderBytes")
	ErrBadEnvelope    = errors.New("envelope: malformed")
	eventIDRe         = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
)

// Route identifies the terminal pane the event came from. All fields optional.
type Route struct {
	Pane          string `json:"pane,omitempty"`           // LC_ROOTSHELL_PANE (surface UUID)
	TmuxPane      string `json:"tmux_pane,omitempty"`      // "%12"
	TmuxServer    string `json:"tmux_server,omitempty"`    // canonical tmux server instance
	TmuxSession   string `json:"tmux_session,omitempty"`   // tmux session name
	HerdrServer   string `json:"herdr_server,omitempty"`   // hashed host/uid/socket namespace
	HerdrTerminal string `json:"herdr_terminal,omitempty"` // stable server-owned terminal ID
	HerdrPane     string `json:"herdr_pane,omitempty"`     // public pane ID; hint only
	Host          string `json:"host,omitempty"`           // user@hostname
	Cwd           string `json:"cwd,omitempty"`
}

// Header is the plaintext protected by Seal.
type Header struct {
	V      int    `json:"v"`
	Kind   string `json:"kind"`             // agent | generic
	Agent  string `json:"agent,omitempty"`  // claude-code | codex | ...
	Status string `json:"status,omitempty"` // done | blocked | failed | info
	Title  string `json:"title"`
	Body   string `json:"body,omitempty"`
	Thread string `json:"thread,omitempty"` // opaque per-session id for grouping
	Route  *Route `json:"route,omitempty"`
}

// Envelope is the "rs" object carried in the APNs payload and in POST /v1/push.
type Envelope struct {
	V   int    `json:"v"`
	Enc string `json:"enc"`
	CT  string `json:"ct"`
	EID string `json:"eid"`
}

var b64 = base64.RawURLEncoding

func aad(eid string) []byte { return []byte("eid:" + eid) }

// ValidateEventID reports whether eid is safe to use as a dedupe key and AAD.
func ValidateEventID(eid string) error {
	if !eventIDRe.MatchString(eid) {
		return fmt.Errorf("%w: event id", ErrBadEnvelope)
	}
	return nil
}

// Seal encrypts h for pk, binding it to eid.
func Seal(pk *PublicKey, eid string, h *Header) (*Envelope, error) {
	if err := ValidateEventID(eid); err != nil {
		return nil, err
	}
	if h.V == 0 {
		h.V = Version
	}
	pt, err := json.Marshal(h)
	if err != nil {
		return nil, err
	}
	if len(pt) > MaxHeaderBytes {
		return nil, ErrHeaderTooLarge
	}
	enc, s, err := hpke.NewSender(pk.k, kdf(), aead(), []byte(Info))
	if err != nil {
		return nil, err
	}
	ct, err := s.Seal(aad(eid), pt)
	if err != nil {
		return nil, err
	}
	return &Envelope{V: Version, Enc: b64.EncodeToString(enc), CT: b64.EncodeToString(ct), EID: eid}, nil
}

// Validate checks structure and sizes without any key material; the relay
// uses this to reject junk before forwarding.
func (e *Envelope) Validate() error {
	if e.V != Version {
		return fmt.Errorf("%w: version %d", ErrBadEnvelope, e.V)
	}
	if err := ValidateEventID(e.EID); err != nil {
		return err
	}
	enc, err := b64.DecodeString(e.Enc)
	if err != nil || len(enc) != EncSize {
		return fmt.Errorf("%w: enc", ErrBadEnvelope)
	}
	ct, err := b64.DecodeString(e.CT)
	if err != nil || len(ct) < 16 || len(ct) > MaxHeaderBytes+16 {
		return fmt.Errorf("%w: ct", ErrBadEnvelope)
	}
	return nil
}

// Open decrypts e with sk.
func Open(sk *PrivateKey, e *Envelope) (*Header, error) {
	if err := e.Validate(); err != nil {
		return nil, err
	}
	enc, _ := b64.DecodeString(e.Enc)
	ct, _ := b64.DecodeString(e.CT)
	r, err := hpke.NewRecipient(enc, sk.k, kdf(), aead(), []byte(Info))
	if err != nil {
		return nil, err
	}
	pt, err := r.Open(aad(e.EID), ct)
	if err != nil {
		return nil, err
	}
	var h Header
	if err := json.Unmarshal(pt, &h); err != nil {
		return nil, err
	}
	if h.V != Version {
		return nil, fmt.Errorf("%w: header version %d", ErrBadEnvelope, h.V)
	}
	return &h, nil
}
