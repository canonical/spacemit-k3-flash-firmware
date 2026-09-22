#!/usr/bin/env python3
"""Dump an MTD partition (or raw memory) from the K3 fastboot agent.

Uses the vendor's stock 'oem read:<part>' + 'upload:' wire protocol
(no agent rebuild needed). Requires pyusb: sudo apt install python3-usb

Usage:
  ./fastboot-dump.py <partition> <out.bin>          # whole partition
  ./fastboot-dump.py mem <out.bin> <addr> <size>     # raw memory (hex)
Examples:
  ./fastboot-dump.py fsbl fsbl-raw.bin
  ./fastboot-dump.py bootinfo bootinfo-raw.bin
"""
import sys
import usb.core
import usb.util

VID, PID = 0x361c, 0x1001

# active interface, claimed for I/O (released via atexit)
_intf = None
_dev = None


def find_endpoints():
    global _dev, _intf
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        sys.exit("no fastboot device (361c:1001) — put the board in FDL mode and re-run")
    try:
        dev.set_configuration()
    except usb.core.USBError:
        pass  # already configured
    cfg = dev.get_active_configuration()
    # fastboot = one vendor interface with two BULK endpoints.
    # Bulk is bmAttributes&0x03 == 2; direction is the 0x80 bit of bEndpointAddress.
    intf = None
    for i in cfg:
        bulk = [e for e in i.endpoints() if (e.bmAttributes & 0x03) == 0x02]
        outs = [e for e in bulk if not (e.bEndpointAddress & 0x80)]
        ins = [e for e in bulk if (e.bEndpointAddress & 0x80)]
        if outs and ins:
            intf = i
            ep_out, ep_in = outs[0], ins[0]
            break
    if intf is None:
        sys.exit("no interface with in+out bulk endpoints found on the device")
    try:
        usb.util.claim_interface(dev, intf)
    except usb.core.USBError as e:
        sys.exit(f"could not claim USB interface ({e}) — another fastboot process running?")
    _dev, _intf = dev, intf
    return ep_out, ep_in


def release():
    global _intf
    if _dev is not None and _intf is not None:
        try:
            usb.util.release_interface(_dev, _intf)
        except usb.core.USBError:
            pass
        _intf = None


def read_response(ep_in):
    # U-Boot sends responses unpadded (short transfers); one read(64) gets it.
    buf = bytes(ep_in.read(64, timeout=15000))
    status = buf[:4].decode(errors='replace')
    return status, buf[4:].decode(errors='replace').strip('\x00').strip()


def send(ep_out, s):
    data = s.encode()
    assert len(data) <= 64
    ep_out.write(data.ljust(64, b'\x00'))


def parse_size(rest):
    rest = rest.strip()
    if rest.lower().startswith('0x'):
        rest = rest[2:]
    return int(rest[:8], 16)


def main():
    args = sys.argv[1:]
    if len(args) == 4 and args[0] == 'mem':
        out, cmd = args[1], f"oem read:mem {args[2]} {args[3]}"
    elif len(args) == 2:
        out, cmd = args[1], f"oem read:{args[0]}"
    else:
        sys.exit(__doc__)

    ep_out, ep_in = find_endpoints()
    try:
        print(f"-> {cmd}")
        send(ep_out, cmd)
        status, rest = read_response(ep_in)
        print(f"<- {status} {rest}")
        if status != 'OKAY':
            sys.exit("agent refused the read")
        size = parse_size(rest)
        if size == 0:
            sys.exit("agent staged 0 bytes")

        print(f"staged {size:#x} bytes, uploading")
        send(ep_out, "upload:")
        status, rest = read_response(ep_in)
        print(f"<- {status} {rest}")
        if status != 'DATA':
            sys.exit(f"expected DATA<size>, got {status}")

        data = b''
        while len(data) < size:
            chunk = ep_in.read(min(0x20000, size - len(data)), timeout=30000)
            if not chunk:
                sys.exit(f"stalled at {len(data)}/{size}")
            data += bytes(chunk)
        open(out, 'wb').write(data)
        print(f"wrote {len(data)} bytes to {out}")

        status, rest = read_response(ep_in)  # final OKAY
        print(f"<- {status} {rest} (final)")
    finally:
        release()


if __name__ == '__main__':
    main()
