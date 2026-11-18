package dnsprobe

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func response(query []byte) []byte {
	if len(query) < 12 {
		return nil
	}
	end := 12
	for end < len(query) && query[end] != 0 {
		end += int(query[end]) + 1
	}
	end += 5 // terminating label and QTYPE/QCLASS
	if end > len(query) {
		return nil
	}
	out := append([]byte(nil), query[:end]...)
	out[2], out[3] = 0x81, 0x80
	out[6], out[7] = 0, 1
	out[10], out[11] = 0, 0
	out = append(out, 0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1)
	return out
}

func TestCheckRequiresUDPAndTCP(t *testing.T) {
	tcp, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Skipf("loopback TCP listener unavailable: %v", err)
	}
	defer tcp.Close()
	udp, err := net.ListenPacket("udp4", tcp.Addr().String())
	if err != nil {
		t.Skipf("loopback UDP listener unavailable: %v", err)
	}
	defer udp.Close()
	probe, err := net.Dial("udp4", udp.LocalAddr().String())
	if err != nil {
		t.Skipf("loopback UDP unavailable: %v", err)
	}
	_, err = probe.Write([]byte{1})
	probe.Close()
	if err != nil {
		t.Skipf("loopback UDP unavailable: %v", err)
	}
	_ = udp.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
	if _, _, err := udp.ReadFrom(make([]byte, 1)); err != nil {
		t.Skipf("loopback UDP unavailable: %v", err)
	}
	_ = udp.SetReadDeadline(time.Time{})
	go func() {
		buf := make([]byte, 4096)
		for {
			n, peer, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = udp.WriteTo(response(buf[:n]), peer)
		}
	}()
	go func() {
		for {
			conn, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var size [2]byte
				if _, err := io.ReadFull(conn, size[:]); err != nil {
					return
				}
				query := make([]byte, binary.BigEndian.Uint16(size[:]))
				if _, err := io.ReadFull(conn, query); err != nil {
					return
				}
				reply := response(query)
				binary.BigEndian.PutUint16(size[:], uint16(len(reply)))
				_, _ = conn.Write(append(size[:], reply...))
			}()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := Check(ctx, tcp.Addr().String(), "example.invalid."); err != nil {
		t.Fatal(err)
	}
	tcp.Close()
	ctx2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if err := Check(ctx2, udp.LocalAddr().String(), "example.invalid."); err == nil {
		t.Fatal("accepted unavailable TCP listener")
	}
}
