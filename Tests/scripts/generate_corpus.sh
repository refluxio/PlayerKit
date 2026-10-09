#!/usr/bin/env bash
# HDR/DV 验证语料合成脚本(P0)。可重跑再生;产物入 git。
# 用法: Tests/scripts/generate_corpus.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_DIR="$SCRIPT_DIR/../PlayerKitTests/Fixtures/corpus"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FPS=24; SIZE=256x144; DUR=1; FRAMES=$((FPS * DUR))

require() { # require <tool> <brew-name>
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少工具: $1 —— 安装: brew install $2"; exit 1; }
}
require ffmpeg ffmpeg; require ffprobe ffmpeg; require x265 x265
require jq jq; require dovi_tool dovi_tool; require hdr10plus_tool hdr10plus_tool
require python3 python3

mkdir -p "$CORPUS_DIR"

# ---------- 基础源(动画 testsrc2,保证三帧内容不同) ----------
ffmpeg -v error -y -f lavfi -i "testsrc2=size=$SIZE:rate=$FPS:duration=$DUR" \
  -pix_fmt yuv420p -strict -1 "$TMP/sdr.y4m"
ffmpeg -v error -y -f lavfi -i "testsrc2=size=$SIZE:rate=$FPS:duration=$DUR" \
  -pix_fmt yuv420p10le -strict -1 "$TMP/hdr.y4m"

# ---------- C1: SDR bt709 ----------
# 注:简报原文在 -o 后多一个位置参数 "-",x265 视为多余参数直接 exit 1,已去掉。
x265 --input "$TMP/sdr.y4m" --fps $FPS --colorprim bt709 --transfer bt709 \
  --colormatrix bt709 --repeat-headers --no-info -o "$TMP/c1.265" 2>/dev/null
ffmpeg -v error -y -i "$TMP/c1.265" -c copy "$CORPUS_DIR/c1_sdr_bt709.mp4"

# ---------- C2: HDR10 (PQ/BT.2020 + ST2086 + CLL) ----------
# 注:必须显式 --profile main10 —— 本机 homebrew x265 只给 --input-depth 10 时会
# 静默降成 8-bit Main(实测 profile=Main/pix_fmt yuv420p),语料第一次生成即中招。
x265 --input "$TMP/hdr.y4m" --input-depth 10 --profile main10 --fps $FPS \
  --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc \
  --hdr10 --master-display "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)" \
  --max-cll "1000,400" --repeat-headers -o "$TMP/c2.265" 2>/dev/null
ffmpeg -v error -y -i "$TMP/c2.265" -c copy "$CORPUS_DIR/c2_hdr10.mp4"
ffmpeg -v error -y -i "$CORPUS_DIR/c2_hdr10.mp4" -c:v copy \
  -bsf:v hevc_mp4toannexb -f hevc "$TMP/c2.annexb.265"

# ---------- C3: HDR10+ (C2 + ST 2094-40 注入) ----------
# 单帧模板展开为 24 帧(帧号递增)。
jq --argjson n $FRAMES '(.SceneInfo[0]) as $f |
  .SceneInfo = [range(0; $n) as $i | $f | .SceneFrameIndex = $i | .SequenceFrameIndex = $i]' \
  "$SCRIPT_DIR/hdr10plus_meta_frame.json" > "$TMP/hdr10plus_meta.json"
hdr10plus_tool inject -i "$TMP/c2.annexb.265" -j "$TMP/hdr10plus_meta.json" -o "$TMP/c3.265"
ffmpeg -v error -y -i "$TMP/c3.265" -c copy "$CORPUS_DIR/c3_hdr10plus.mp4"

# ---------- C4: HLG ----------
# 注:简报原文的 --transfer-characteristic 不是 x265 选项(unrecognized option),
# x265 的选项是 --transfer,HLG = arib-std-b67(=ITU-R BT.2100 value 18)。
# 同 C2:必须显式 --profile main10,否则 homebrew x265 静默降 8-bit。
x265 --input "$TMP/hdr.y4m" --input-depth 10 --profile main10 --fps $FPS \
  --colorprim bt2020 --transfer arib-std-b67 --colormatrix bt2020nc \
  --repeat-headers -o "$TMP/c4.265" 2>/dev/null
ffmpeg -v error -y -i "$TMP/c4.265" -c copy "$CORPUS_DIR/c4_hlg.mp4"

# ---------- C5: DV P8.1 (C2 BL + dovi_tool 生成 RPU 注入) ----------
# 注:简报原文用 -i,dovi_tool generate 只认 -j/--json(其余子命令才用 -i)。
dovi_tool generate -j "$SCRIPT_DIR/l1_metadata.json" -o "$TMP/RPU.bin"
dovi_tool inject-rpu -i "$TMP/c2.annexb.265" -r "$TMP/RPU.bin" -o "$TMP/c5.265"
ffmpeg -v error -y -i "$TMP/c5.265" -c copy "$CORPUS_DIR/c5_dv_p81.mp4"
# ffmpeg 8.x 的 raw HEVC demuxer 不产生 DOVI_CONF side data,movenc 因此不写 dvcC;
# 由 patch_dvcc.py 按规格写入 dvcC(profile 8 / rpu=1 / el=0 / bl=1 / compat_id=1)。
python3 "$SCRIPT_DIR/patch_dvcc.py" "$CORPUS_DIR/c5_dv_p81.mp4"

# ---------- C9: DV-over-TS (C5 经 mpegts 封装,断言 DOVI registration descriptor) ----------
# 注意:ffmpeg 8.x 的 mpegts muxer 不写 DOVI registration descriptor(mpegtsenc.c 无此逻辑,
# demux 侧倒是可以解析)。TS 内 RPU NAL 完整保留;DOVI 断言由 Task 4 的 reader 注入路径承担。
ffmpeg -v error -y -i "$CORPUS_DIR/c5_dv_p81.mp4" -map 0:v:0 -c:v copy \
  -bsf:v hevc_mp4toannexb -f mpegts "$CORPUS_DIR/c9_dv_ts.ts"

# ---------- 权威值测量 + 与期望核对 ----------
# 期望段 = 矩阵表(spec §3.1)落地,strategy case 名与 RendererStrategy.swift 实际声明一致。
cat > "$TMP/expected.json" <<'EOF'
{
  "cells": [
    { "file": "c1_sdr_bt709.mp4", "cell": "SDR_bt709", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "bt709", "primaries": "bt709", "matrix": "bt709",
        "dv_profile": 0, "dv_rpu_present": false, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 0, "hdr10plus": false },
      "expected": { "strategyEDR": "sdr8Bit(bt709)", "strategySDR": "sdr8Bit(bt709)",
        "isDoVi": false, "doviProfile": 0, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "c2_hdr10.mp4", "cell": "HDR10", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "smpte2084", "primaries": "bt2020", "matrix": "bt2020nc",
        "dv_profile": 0, "dv_rpu_present": false, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 0, "hdr10plus": false },
      "expected": { "strategyEDR": "hdr10Static(1000)", "strategySDR": "hdr10Static(1000)",
        "isDoVi": false, "doviProfile": 0, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "c3_hdr10plus.mp4", "cell": "HDR10+", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "smpte2084", "primaries": "bt2020", "matrix": "bt2020nc",
        "dv_profile": 0, "dv_rpu_present": false, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 0, "hdr10plus": true },
      "expected": { "strategyEDR": "hdr10Plus", "strategySDR": "hdr10Static(1000)",
        "isDoVi": false, "doviProfile": 0, "hasHDR10Plus": true, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "c4_hlg.mp4", "cell": "HLG", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "arib-std-b67", "primaries": "bt2020", "matrix": "bt2020nc",
        "dv_profile": 0, "dv_rpu_present": false, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 0, "hdr10plus": false },
      "expected": { "strategyEDR": "hlgOOTF", "strategySDR": "hdr10Static(1000)",
        "isDoVi": false, "doviProfile": 0, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "c5_dv_p81.mp4", "cell": "DV_P8.1", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "smpte2084", "primaries": "bt2020", "matrix": "bt2020nc",
        "dv_profile": 8, "dv_rpu_present": true, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 1, "hdr10plus": false },
      "expected": { "strategyEDR": "doviProfile8(false)", "strategySDR": "degradedHDR10",
        "isDoVi": true, "doviProfile": 8, "hasHDR10Plus": false, "blSignalCompatibilityId": 1 },
      "discDovi": null },
    { "file": "c9_dv_ts.ts", "cell": "DV_TS", "synthetic": true, "realCorpus": null,
      "ffprobe": { "codec": "hevc", "trc": "smpte2084", "primaries": "bt2020", "matrix": "bt2020nc",
        "dv_profile": 0, "dv_rpu_present": false, "dv_el_present": false,
        "dv_bl_signal_compatibility_id": 0, "hdr10plus": false },
      "expected": { "strategyEDR": "doviProfile8(false)", "strategySDR": "degradedHDR10",
        "isDoVi": true, "doviProfile": 8, "hasHDR10Plus": false, "blSignalCompatibilityId": 1 },
      "discDovi": { "profile": 8, "rpu": true, "el": false, "bl": true, "compatId": 1 },
      "note": "ffmpeg 8.x mpegts muxer 不写 DOVI registration descriptor(mpegts demuxer 可解析),故 ffprobe 段无 DOVI 字段是工具限制的实测记录;TS 内 RPU NAL 完整保留,DOVI 断言由 Task 4 的 reader 注入路径承担" },
    { "file": "", "cell": "DV_P5", "synthetic": false,
      "realCorpus": { "subdir": "c6_dv_p5", "patterns": ["*.mkv", "*.mp4", "*.ts", "*.m2ts"] },
      "ffprobe": null,
      "expected": { "strategyEDR": "doviProfile5", "strategySDR": "degradedHDR10",
        "isDoVi": true, "doviProfile": 5, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "", "cell": "DV_P7_full", "synthetic": false,
      "realCorpus": { "subdir": "c7_dv_p7_full", "patterns": ["*.mkv", "*.ts", "*.m2ts"] },
      "ffprobe": null,
      "expected": { "strategyEDR": "degradedHDR10", "strategySDR": "degradedHDR10",
        "isDoVi": true, "doviProfile": 7, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": { "profile": 7, "rpu": true, "el": true, "bl": true, "compatId": 0 } },
    { "file": "", "cell": "HDR10_disc_noDV", "synthetic": false,
      "realCorpus": { "subdir": "c8_avengers_hdr10_disc", "patterns": ["*.m2ts", "*.ts"] },
      "ffprobe": null,
      "expected": { "strategyEDR": "hdr10Static(1000)", "strategySDR": "hdr10Static(1000)",
        "isDoVi": false, "doviProfile": 0, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null },
    { "file": "", "cell": "DV_ISO", "synthetic": false,
      "realCorpus": { "subdir": "c10_dv_iso", "patterns": ["*.iso"] },
      "ffprobe": null,
      "expected": { "strategyEDR": "degradedHDR10", "strategySDR": "degradedHDR10",
        "isDoVi": true, "doviProfile": 7, "hasHDR10Plus": false, "blSignalCompatibilityId": 0 },
      "discDovi": null }
  ]
}
EOF

MEASURED="$TMP/measured.json"; echo '{}' > "$MEASURED"
# HDR10+ (ST 2094-40) 是带内 SEI:mp4 等容器不落流级 side data,只能从帧级
# (hevc parser 解出的 user-data SEI)探测。按 "2094-40" 子串匹配,容忍 ffmpeg 版本间的命名差异
# (ffmpeg 8.1.2 实际名字为 "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)")。
probe_hdr10plus() { # probe_hdr10plus <file> → true/false
  ffprobe -v quiet -print_format json -show_frames -select_streams v:0 "$1" \
    | jq '[.frames[]? | .side_data_list // [] | .[]
           | select(.side_data_type | test("2094-40"; "i"))] | length > 0'
}
extract() { # extract <file> → 权威 ffprobe 段(流级字段 + 帧级 HDR10+)
  local f="$1" hdr10plus
  hdr10plus=$(probe_hdr10plus "$f")
  ffprobe -v quiet -print_format json -show_streams -select_streams v:0 "$f" | jq --argjson hdr10plus "$hdr10plus" '{
    codec:     .streams[0].codec_name,
    trc:       (.streams[0].color_transfer // "unknown"),
    primaries: (.streams[0].color_primaries // "unknown"),
    matrix:    (.streams[0].color_space // "unknown"),
    dv_profile: ([.streams[0].side_data_list // [] | .[] | select(.side_data_type == "DOVI configuration record")][0].dv_profile // 0),
    dv_rpu_present: (([.streams[0].side_data_list // [] | .[] | select(.side_data_type == "DOVI configuration record")][0].rpu_present_flag == 1)),
    dv_el_present: (([.streams[0].side_data_list // [] | .[] | select(.side_data_type == "DOVI configuration record")][0].el_present_flag == 1)),
    dv_bl_signal_compatibility_id: ([.streams[0].side_data_list // [] | .[] | select(.side_data_type == "DOVI configuration record")][0].dv_bl_signal_compatibility_id // 0),
    hdr10plus: $hdr10plus
  }'
}
fail=0
for f in c1_sdr_bt709.mp4 c2_hdr10.mp4 c3_hdr10plus.mp4 c4_hlg.mp4 c5_dv_p81.mp4 c9_dv_ts.ts; do
  cell=$(jq -r --arg f "$f" '.cells[] | select(.file==$f) | .cell' "$TMP/expected.json")
  m=$(extract "$CORPUS_DIR/$f")
  jq --arg c "$cell" --argjson m "$m" '.[$c] = $m' "$MEASURED" > "$MEASURED.new" && mv "$MEASURED.new" "$MEASURED"
  for key in codec trc primaries matrix dv_profile dv_rpu_present dv_el_present dv_bl_signal_compatibility_id hdr10plus; do
    exp=$(jq -r --arg c "$cell" --arg k "$key" '.cells[] | select(.cell==$c) | .ffprobe[$k] | tostring' "$TMP/expected.json")
    act=$(jq -r --arg c "$cell" --arg k "$key" '.[$c][$k] | tostring' "$MEASURED")
    if [ "$act" != "$exp" ]; then
      echo "❌ $cell ffprobe.$key 期望=$exp 实测=$act(语料或工具版本漂移,先核对再改 expected)"; fail=1
    fi
  done
done
[ "$fail" = 0 ] || exit 1

# ---------- 全部核对通过:合成 manifest.json(expected + 实测 ffprobe)----------
jq --slurpfile measured "$MEASURED" '
  .cells |= map(if .synthetic then .ffprobe = $measured[0][.cell] else . end)' \
  "$TMP/expected.json" > "$CORPUS_DIR/manifest.json"
cp "$TMP/expected.json" "$CORPUS_DIR/manifest.expected.json"

# ---------- 尺寸红线:< 2MB ----------
for f in "$CORPUS_DIR"/*.mp4 "$CORPUS_DIR"/*.ts; do
  kb=$(du -k "$f" | cut -f1)
  [ "$kb" -lt 2048 ] || { echo "❌ $f ${kb}KB 超过 2MB 红线"; exit 1; }
done
echo "✅ 语料生成完成: $(ls "$CORPUS_DIR" | wc -l | tr -d ' ') 个文件于 $CORPUS_DIR"
