#!/usr/bin/env python3
"""向 HEVC-in-MP4 的 sample entry 插入标准 Dolby Vision 配置 box(dvcC)。

背景:ffmpeg 8.x 的 raw HEVC demuxer 不产生 DOVI_CONF side data,movenc 只在
流上已有该 side data 时(且 -strict unofficial)才写 dvcC/dvvC。因此由
dovi_tool inject-rpu 得到的 RPU 流直接 mux 进 mp4 会丢失 DOVI 配置声明。

本脚本按 ff_isom_parse_dvcc_dvvc 的位布局(libavformat/dovi_isom.c)手工写入
一个规格正确的 dvcC box:profile 8、rpu=1、el=0、bl=1、bl_signal_compatibility_id=1。
moov 必须是最后一个 top-level box(ffmpeg 默认布局),否则 chunk 偏移会失效,拒绝打补丁。
"""
import sys

DVCC_PAYLOAD = bytes(
    [0x01, 0x00]  # dv_version_major=1, minor=0
    # 7b profile=8 | 6b level=0 | 1b rpu=1 | 1b el=0 | 1b bl=1  -> 0x1005
    + [0x10, 0x05]
    # 4b bl_signal_compatibility_id=1 | 2b dv_md_compression=1(limited) | 2b reserved
    + [0x14]
    + [0x00] * 19  # reserved
)
assert len(DVCC_PAYLOAD) == 24
DVCC_BOX = (32).to_bytes(4, "big") + b"dvcC" + DVCC_PAYLOAD


def boxes(data, start, end):
    off = start
    while off + 8 <= end:
        size = int.from_bytes(data[off : off + 4], "big")
        hdr = 8
        if size == 1:
            size = int.from_bytes(data[off + 8 : off + 16], "big")
            hdr = 16
        elif size == 0:
            size = end - off
        if size < hdr or off + size > end:
            raise ValueError(f"非法 box 尺寸 @ {off:#x}")
        yield off, size, hdr
        off += size


def find(data, start, end, fourcc):
    for off, size, hdr in boxes(data, start, end):
        if data[off + 4 : off + 8] == fourcc:
            return off, off + size, off + hdr
    return None


def main(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    n = len(data)

    moov = None
    for off, size, hdr in boxes(data, 0, n):
        if data[off + 4 : off + 8] == b"moov":
            if off + size != n:
                sys.exit(f"拒绝打补丁: moov 之后还有别的 box @ {off:#x}(会破坏 chunk 偏移)")
            moov = (off, off + size, off + hdr)
    if moov is None:
        sys.exit("未找到 moov")
    moov_s, moov_e, moov_b = moov

    # 链上所有 container 的 size 字段偏移 + sample entry 信息
    chain = []  # (box_start_offset_of_size_field, current_size)
    entry = None
    for t_off, t_size, t_hdr in boxes(data, moov_b, moov_e):
        if data[t_off + 4 : t_off + 8] != b"trak":
            continue
        mdia = find(data, t_off + t_hdr, t_off + t_size, b"mdia")
        minf = find(data, mdia[2], mdia[1], b"minf") if mdia else None
        stbl = find(data, minf[2], minf[1], b"stbl") if minf else None
        stsd = find(data, stbl[2], stbl[1], b"stsd") if stbl else None
        if not (mdia and minf and stbl and stsd):
            continue
        s_s, s_e, s_b = stsd
        # stsd body: version/flags(4) + entry_count(4) + entries
        entry_count = int.from_bytes(data[s_b + 4 : s_b + 8], "big")
        entry_off = s_b + 8
        if entry_count >= 1:
            fcc = bytes(data[entry_off + 4 : entry_off + 8])
            if fcc in (b"hvc1", b"hev1"):
                entry_size = int.from_bytes(data[entry_off : entry_off + 4], "big")
                entry_e = entry_off + entry_size
                entry = (entry_off, entry_size, entry_e)
                chain = [
                    moov_s,
                    t_off,
                    mdia[0],
                    minf[0],
                    stbl[0],
                    s_s,
                    entry_off,
                ]
                break
    if entry is None:
        sys.exit("未找到 hvc1/hev1 sample entry")
    entry_off, _entry_size, entry_e = entry

    # 幂等:扫描 sample entry 的子 box,已有 DOVI 配置则跳过
    has_dvcc = False
    for _o, _sz, _hdr in boxes(data, entry_off + 8, entry_e):
        if bytes(data[_o + 4 : _o + 8]) in (b"dvcC", b"dvvC", b"dvwC"):
            has_dvcc = True
            break
    if has_dvcc:
        print("已存在 DOVI 配置 box,跳过")
        return

    data[entry_e:entry_e] = DVCC_BOX
    for off in chain:
        old = int.from_bytes(data[off : off + 4], "big")
        if old >= (1 << 31):
            sys.exit(f"拒绝打补丁: chain 上出现 largesize box @ {off:#x}")
        data[off : off + 4] = (old + 32).to_bytes(4, "big")

    with open(path, "wb") as f:
        f.write(data)
    print(f"已插入 dvcC(profile 8, rpu=1, el=0, bl=1, compat_id=1)@ {path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"用法: {sys.argv[0]} <video.mp4>")
    main(sys.argv[1])
