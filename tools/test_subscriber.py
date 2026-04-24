#!/usr/bin/env python3
"""Test subscriber for ClipBrdComp protocol v1
Connects, performs HELLO->AUTH->ANNOUNCE->SUBSCRIBE_GROUP and prints CLIP_PUSH frames.
"""
import socket, struct, time, binascii, uuid, sys

CB_MAGIC = b'CB'
CB_VERSION = 1
CB_HEADER_SIZE = 36

MSG_HELLO = 0x01
MSG_AUTH = 0x03
MSG_ANNOUNCE = 0x05
MSG_SUBSCRIBE_GROUP = 0x50
MSG_CLIP_PUSH = 0x11

ENC_UTF8 = 0x01

CLIENT_VERSION = 0x00010000
MIN_PROTOCOL = 0x00010000
DEFAULT_GROUP_ID = b"\x00" * 15 + b"\x01"


def pack_pascal_str(s: str) -> bytes:
    b = s.encode('utf-8')
    if len(b) > 255:
        b = b[:255]
    return struct.pack('B', len(b)) + b


def build_hello(hostname='py-sub', ostype=0x01):
    payload = struct.pack('>I', CLIENT_VERSION) + struct.pack('>I', MIN_PROTOCOL)
    payload += struct.pack('B', ostype)
    payload += pack_pascal_str(hostname)
    return payload


def build_auth(token: str):
    return pack_pascal_str(token)


def build_announce(ostype=0x01, profile='PY_SUB', formats=0x00000001, max_payload_kb=4096, cap_flags=0x02, osversion=''):
    p = struct.pack('B', ostype)
    p += pack_pascal_str(profile)
    p += struct.pack('>I', formats)
    p += struct.pack('>H', max_payload_kb)
    p += struct.pack('B', cap_flags)
    p += pack_pascal_str(osversion)
    return p


def build_subscribe(group_id: bytes = DEFAULT_GROUP_ID, mode: int = 2):
    return group_id + struct.pack('B', mode)


def build_frame(msgtype: int, nodeid: bytes, seqnum: int, payload: bytes, flags: int = 0):
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


def parse_clip_push(payload: bytes):
    # ClipID(16) SourceNodeID(16) GroupID(16) Format(1) Encoding(1) reserved(2) Hash(16) ContentLen(4 BE) Content
    pos = 0
    clipid = payload[pos:pos+16]; pos += 16
    srcnode = payload[pos:pos+16]; pos += 16
    groupid = payload[pos:pos+16]; pos += 16
    fmt = payload[pos]; pos += 1
    enc = payload[pos]; pos += 1
    pos += 2
    h = payload[pos:pos+16]; pos += 16
    content_len = struct.unpack('>I', payload[pos:pos+4])[0]; pos += 4
    content = payload[pos:pos+content_len] if content_len>0 else b''
    return clipid, srcnode, groupid, fmt, enc, h, content


if __name__ == '__main__':
    host = sys.argv[1] if len(sys.argv) > 1 else '127.0.0.1'
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 6543

    nodeid = uuid.uuid4().bytes
    seq = 1

    print('Connecting to', host, port)
    s = socket.create_connection((host, port), timeout=10)
    s.settimeout(10)

    try:
        # HELLO
        s.sendall(build_frame(MSG_HELLO, nodeid, seq, build_hello(hostname='py-sub', ostype=0x01)))
        seq += 1
        time.sleep(0.1)
        # AUTH
        s.sendall(build_frame(MSG_AUTH, nodeid, seq, build_auth('clipbrdcomp_secret_2025')))
        seq += 1
        time.sleep(0.1)
        # ANNOUNCE
        s.sendall(build_frame(MSG_ANNOUNCE, nodeid, seq, build_announce()))
        seq += 1
        time.sleep(0.1)
        # SUBSCRIBE
        s.sendall(build_frame(MSG_SUBSCRIBE_GROUP, nodeid, seq, build_subscribe()))
        seq += 1

        print('Subscribed; listening for CLIP_PUSH...')
        s.settimeout(None)
        while True:
            try:
                mtype, nid, rseq, ts, pld = read_frame(s)
            except Exception as e:
                print('Read frame error:', e)
                break
            if mtype == MSG_CLIP_PUSH:
                clipid, srcnode, groupid, fmt, enc, h, content = parse_clip_push(pld)
                print('CLIP_PUSH received: fmt=0x%02x len=%d from=%s' % (fmt, len(content), binascii.hexlify(srcnode).decode()))
                if fmt == 0x01:  # text utf8
                    try:
                        print('-- TEXT --\n', content.decode('utf-8'))
                    except Exception:
                        print('-- TEXT (decode error) --', content)
            else:
                print('Incoming msg', hex(mtype), 'len', len(pld))

    finally:
        s.close()
        print('Subscriber exiting')
