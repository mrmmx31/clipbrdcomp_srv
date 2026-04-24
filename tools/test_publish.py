#!/usr/bin/env python3
"""Test client for ClipBrdComp protocol v1
Performs HELLO -> AUTH -> ANNOUNCE -> CLIP_PUBLISH to a broker
"""
import socket, struct, time, binascii, uuid, sys

# Constants from protocol/cbprotocol.pas
CB_MAGIC = b'CB'
CB_VERSION = 1
CB_HEADER_SIZE = 36

MSG_HELLO = 0x01
MSG_AUTH = 0x03
MSG_ANNOUNCE = 0x05
MSG_CLIP_PUBLISH = 0x10

FMT_TEXT_UTF8 = 0x01
FMT_TEXT_ANSI = 0x02
ENC_UTF8 = 0x01

CLIENT_VERSION = 0x00010000
MIN_PROTOCOL = 0x00010000

DEFAULT_GROUP_ID = b"\x00" * 15 + b"\x01"

# helpers

def pack_pascal_str(s: str) -> bytes:
    b = s.encode('utf-8')
    if len(b) > 255:
        b = b[:255]
    return struct.pack('B', len(b)) + b


def be32(v):
    return struct.pack('>I', v)


def now_unix():
    return int(time.time())


def build_hello(hostname='pytest', ostype=0x10):
    payload = struct.pack('>I', CLIENT_VERSION) + struct.pack('>I', MIN_PROTOCOL)
    payload += struct.pack('B', ostype)
    payload += pack_pascal_str(hostname)
    return payload


def build_auth(token: str):
    return pack_pascal_str(token)


def build_announce(ostype=0x10, profile='WIN98_LEGACY', formats=0x00000001, max_payload_kb=4096, cap_flags=0x06, osversion=''):
    p = struct.pack('B', ostype)
    p += pack_pascal_str(profile)
    p += struct.pack('>I', formats)
    p += struct.pack('>H', max_payload_kb)
    p += struct.pack('B', cap_flags)
    p += pack_pascal_str(osversion)
    return p


def build_clip_publish(content_bytes: bytes, format_type=FMT_TEXT_UTF8, orig_os_format=FMT_TEXT_ANSI):
    clip_id = uuid.uuid4().bytes
    group_id = DEFAULT_GROUP_ID
    fmt = struct.pack('B', format_type)
    orig = struct.pack('B', orig_os_format)
    enc = struct.pack('B', ENC_UTF8)
    reserved = b'\x00'
    # simple 16-byte hash: use MD5
    try:
        import hashlib
        h = hashlib.md5(content_bytes).digest()
    except Exception:
        h = b'\x00' * 16
    content_len = struct.pack('>I', len(content_bytes))
    payload = clip_id + group_id + fmt + orig + enc + reserved + h + content_len + content_bytes
    return payload


def build_frame(msgtype: int, nodeid: bytes, seqnum: int, payload: bytes, flags: int = 0):
    # header: magic(2) version(1) msgtype(1) flags(1) reserved(3) nodeid(16) seqnum(4 BE) timestamp(4 BE) payloadlen(4 BE)
    hdr = bytearray()
    hdr += CB_MAGIC
    hdr += struct.pack('B', CB_VERSION)
    hdr += struct.pack('B', msgtype)
    hdr += struct.pack('B', flags)
    hdr += b'\x00\x00\x00'
    hdr += nodeid
    hdr += struct.pack('>I', seqnum)
    hdr += struct.pack('>I', int(time.time()))
    hdr += struct.pack('>I', len(payload))
    # CRC over header+payload
    crc = binascii.crc32(bytes(hdr) + payload) & 0xffffffff
    frame = bytes(hdr) + payload + struct.pack('>I', crc)
    return frame


def read_exact(sock: socket.socket, n: int):
    buf = b''
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError('socket closed')
        buf += chunk
    return buf


def read_frame(sock: socket.socket):
    hdr = read_exact(sock, CB_HEADER_SIZE)
    if hdr[0:2] != CB_MAGIC:
        raise ValueError('Bad magic')
    version = hdr[2]
    msgtype = hdr[3]
    # flags = hdr[4]
    # reserved = hdr[5:8]
    nodeid = hdr[8:24]
    seqnum = struct.unpack('>I', hdr[24:28])[0]
    timestamp = struct.unpack('>I', hdr[28:32])[0]
    payloadlen = struct.unpack('>I', hdr[32:36])[0]
    payload = b''
    if payloadlen > 0:
        payload = read_exact(sock, payloadlen)
    crc_bytes = read_exact(sock, 4)
    crc_read = struct.unpack('>I', crc_bytes)[0]
    calc = binascii.crc32(hdr + payload) & 0xffffffff
    if calc != crc_read:
        raise ValueError('CRC mismatch')
    return msgtype, nodeid, seqnum, timestamp, payload


if __name__ == '__main__':
    host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 6543
    text = sys.argv[3] if len(sys.argv) > 3 else f'WIN98-E2E-{int(time.time())}'

    nodeid = uuid.uuid4().bytes
    seq = 1

    print('Connecting to', host, port)
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)

    try:
        # HELLO
        hello_payload = build_hello(hostname='pytest', ostype=0x10)
        f = build_frame(MSG_HELLO, nodeid, seq, hello_payload)
        seq += 1
        s.sendall(f)
        print('Sent HELLO')

        # read responses until AUTH_ACK maybe
        try:
            mtype, nid, rseq, ts, payload = read_frame(s)
            print('Recv msg', hex(mtype), 'seq', rseq)
        except Exception as e:
            print('No immediate response or error:', e)

        # AUTH
        auth_payload = build_auth('clipbrdcomp_secret_2025')
        s.sendall(build_frame(MSG_AUTH, nodeid, seq, auth_payload))
        seq += 1
        print('Sent AUTH')
        try:
            mtype, nid, rseq, ts, payload = read_frame(s)
            print('Recv after AUTH msg', hex(mtype), 'len', len(payload))
        except Exception as e:
            print('AUTH response error:', e)

        # ANNOUNCE
        announce_payload = build_announce(ostype=0x10, profile='WIN98_LEGACY', formats=0x00000001, max_payload_kb=4096, cap_flags=0x06)
        s.sendall(build_frame(MSG_ANNOUNCE, nodeid, seq, announce_payload))
        seq += 1
        print('Sent ANNOUNCE')
        try:
            mtype, nid, rseq, ts, payload = read_frame(s)
            print('Recv after ANNOUNCE msg', hex(mtype), 'len', len(payload))
        except Exception as e:
            print('ANNOUNCE response error:', e)

        # Send CLIP_PUBLISH
        content = text.encode('utf-8')
        clip_payload = build_clip_publish(content)
        s.sendall(build_frame(MSG_CLIP_PUBLISH, nodeid, seq, clip_payload))
        seq += 1
        print('Sent CLIP_PUBLISH:', text)

        # read any broker responses for a short time
        s.settimeout(2.0)
        t0 = time.time()
        while time.time() - t0 < 3.0:
            try:
                mtype, nid, rseq, ts, payload = read_frame(s)
                print('Incoming msg', hex(mtype), 'len', len(payload))
            except Exception as e:
                # timeout or no more
                break

    finally:
        s.close()
        print('Done')
