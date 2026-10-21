"""Copipe 紹介動画の BGM をプログラムで作る（著作権の心配がない自作の曲）

150 BPM のエレクトロ。コードは王道進行（F - G - Em - Am）。1 小節 = 1.6 秒 = 48 フレーム。
  0 小節目   : 1 拍ごとに「ジャン」とキメ（画面の言葉が 1 拍ごとに出るのに合わせる）
  1 小節目   : スネアの連打とせり上がる音でためて、最後の 1 拍は無音
  2 小節目   : ドロップ（タイトルが出る）。ここからキック・クラップ・ハイハット・うねるベース・刻むコード
  16 小節目〜: メロディが入る
  33 小節目〜: メロディを 1 オクターブ上でも重ね、きらきらしたアルペジオも足す
  45 小節目〜: おわりの場面。49 小節目の「ジャーン」で終わる
場面が変わる小節の前の 2 拍にスネアのおかず、頭にシンバルを入れる
使い方: python3 scripts/make_bgm.py public/bgm.wav 80
（書き出したあと、ffmpeg で音の大きさを -14 LUFS にそろえる）
"""
import os
import subprocess
import sys
import wave

import numpy as np
from scipy.signal import butter, fftconvolve, sosfilt

RATE = 44100
BPM = 150
BEAT = 60 / BPM          # 0.4 秒
STEP = BEAT / 4          # 16 分音符
BAR = BEAT * 4           # 1.6 秒
DROP = 2                 # ドロップの小節
OUTRO = 45               # おわりの場面の小節
END = 49                 # 最後の「ジャーン」の小節
# 動画の場面が始まる小節（src/scenes.tsx の DURATIONS を 48 フレームで割ったもの）
SCENES = [4, 10, 16, 21, 27, 33, 38, OUTRO]

out_path = sys.argv[1] if len(sys.argv) > 1 else "public/bgm.wav"
duration = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
n = int(RATE * duration)
rng = np.random.default_rng(5)

# 楽器ごとのトラック（左右）と、残響・やまびこ（ディレイ）に送るトラック
bus = {name: np.zeros((2, n)) for name in ["drums", "bass", "pad", "lead", "fx"]}
send = np.zeros((2, n))
echo = np.zeros((2, n))


def midi(note):
    return 440.0 * 2 ** ((note - 69) / 12)


def times(length):
    return np.arange(int(length * RATE)) / RATE


def filt(x, cutoff, kind="low", order=2):
    sos = butter(order, cutoff, kind, fs=RATE, output="sos")
    return sosfilt(sos, x)


def add(name, signal, start, pan=0.0, gain=1.0, reverb=0.0, delay=0.0):
    i = int(round(start * RATE))
    if i >= n or i + len(signal) <= 0:
        return
    s = signal[: n - i] * gain
    lgain, rgain = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    for target, amount in ((bus[name], 1.0), (send, reverb), (echo, delay)):
        if amount:
            target[0, i:i + len(s)] += s * lgain * amount
            target[1, i:i + len(s)] += s * rgain * amount


def saw(freq, length, phase=0.0):
    t = times(length)
    return 2 * ((freq * t + phase) % 1.0) - 1


def square(freq, length):
    return np.sign(np.sin(2 * np.pi * freq * times(length)))


def supersaw(freq, length, voices=7, spread=0.016):
    out = np.zeros(int(length * RATE))
    for v in range(voices):
        detune = 1 + spread * (v - (voices - 1) / 2) / ((voices - 1) / 2)
        out += saw(freq * detune, length, rng.random())
    return out / voices


def adsr(length, a, d, s, r):
    t = times(length)
    env = np.where(t < a, t / max(a, 1e-4), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    return env * np.clip((length - t) / max(r, 1e-4), 0, 1)


# 王道進行（1 小節ずつ）: Fmaj7 - G - Em7 - Am
chords = [
    ([53, 57, 60, 64], 41),  # Fmaj7
    ([55, 59, 62, 67], 43),  # G
    ([52, 55, 59, 62], 40),  # Em7
    ([57, 60, 64, 69], 45),  # Am
]

# メロディ（4 小節でひとまわり）。(16 分音符でいつ, 音, 長さ)
melody = [
    (0, 72, 3), (3, 76, 3), (6, 79, 2), (8, 77, 2), (10, 76, 2), (12, 74, 4),
    (16, 74, 3), (19, 77, 3), (22, 79, 2), (24, 81, 2), (26, 79, 2), (28, 77, 2), (30, 76, 2),
    (32, 76, 3), (35, 79, 3), (38, 83, 2), (40, 81, 4), (44, 79, 2), (46, 76, 2),
    (48, 72, 2), (50, 74, 2), (52, 76, 4), (56, 72, 2), (58, 69, 6),
]

# ---- ドラム ----


def kick():
    t = times(0.36)
    freq = 50 + 140 * np.exp(-t * 32)
    body = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t * 9)
    click = filt(rng.standard_normal(len(t)), 3000, "high") * np.exp(-t * 350) * 0.5
    return np.tanh((body + click) * 2.0)


def clap():
    t = times(0.3)
    noise = filt(rng.standard_normal(len(t)), [1000, 4000], "band")
    env = np.zeros_like(t)
    for k, off in enumerate([0, 0.009, 0.018]):
        env += np.where(t >= off, np.exp(-(t - off) * (240 if k < 2 else 18)), 0)
    return noise * env


def snare():
    t = times(0.22)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 30)
    noise = filt(rng.standard_normal(len(t)), 1800, "high") * np.exp(-t * 22)
    return tone * 0.6 + noise * 0.8


def hat(open_=False):
    length = 0.2 if open_ else 0.04
    t = times(length)
    return filt(rng.standard_normal(len(t)), 8000, "high") * np.exp(-t * (16 if open_ else 110))


def crash(length=2.0):
    t = times(length)
    return filt(rng.standard_normal(len(t)), 4500, "high") * np.exp(-t * 1.6)


def snare_roll(start, length, gain=0.5):
    """だんだん細かくなるスネアの連打（ためのところ）"""
    t = start
    while t < start + length - 1e-6:
        progress = (t - start) / length
        step = BEAT / 2 if progress < 0.25 else BEAT / 4 if progress < 0.75 else BEAT / 8
        add("drums", SNARE, t, gain=gain * (0.35 + 0.65 * progress), reverb=0.15)
        t += step


KICK, CLAP, SNARE = kick(), clap(), snare()

# ---- 効果音 ----


def riser(length):
    """せり上がるノイズ（高いほうへ広がっていく）"""
    t = times(length)
    noise = rng.standard_normal(len(t))
    out = np.zeros_like(noise)
    chunks = 40
    size = len(t) // chunks
    for c in range(chunks):
        center = 400 * (9000 / 400) ** (c / chunks)
        seg = slice(c * size, (c + 1) * size if c < chunks - 1 else len(t))
        out[seg] = filt(noise[seg], [center * 0.7, min(center * 1.4, 18000)], "band")
    return out * (t / length) ** 2


def impact():
    t = times(2.0)
    boom = np.sin(2 * np.pi * np.cumsum(38 + 70 * np.exp(-t * 7)) / RATE) * np.exp(-t * 2.4)
    return boom + crash(2.0) * 0.35


def stab(notes, length, cutoff=4200):
    """コードを短く「ジャッ」と鳴らす"""
    out = sum(supersaw(midi(note), length) for note in notes) / len(notes)
    out += sum(supersaw(midi(note + 12), length, voices=3) for note in notes[1:3]) / 6
    return filt(out, cutoff) * adsr(length, 0.003, length * 0.5, 0.5, 0.04)


def lead(note, length):
    """メロディの音（ノコギリ波と矩形波を重ねて、少しビブラート）"""
    t = times(length)
    vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t / 0.15, 0, 1)
    phase = np.cumsum(midi(note) * vib) / RATE
    tone = (2 * ((phase + 0.0) % 1.0) - 1) * 0.5 + (2 * ((phase * 1.006 + 0.3) % 1.0) - 1) * 0.5
    tone += np.sign(np.sin(2 * np.pi * phase * 0.5)) * 0.25
    return filt(tone, 5200) * adsr(length, 0.006, 0.25, 0.7, 0.05)


def pluck(note, length=0.16):
    env = np.exp(-times(length) * 18)
    return filt(saw(midi(note), length) + 0.5 * square(midi(note) * 1.003, length), 4500) * env


# ---- はじまり（0〜1 小節目） ----

# 1 拍ごとのキメ: 王道進行を 1 拍ずつ
for beat, (notes, root) in enumerate(chords):
    t0 = beat * BEAT
    add("drums", KICK, t0, gain=1.0)
    add("drums", CLAP, t0, gain=0.5, reverb=0.25)
    add("drums", crash(0.6), t0, gain=0.12)
    add("pad", stab(notes, BEAT * 0.8, 5200), t0, gain=0.55, reverb=0.35)
    sub = np.sin(2 * np.pi * midi(root) * times(BEAT * 0.8)) * adsr(BEAT * 0.8, 0.003, 0.2, 0.5, 0.05)
    add("bass", sub, t0, gain=0.5)

# ため: 8 分のキック、スネアの連打、せり上がる音。最後の 1 拍は無音
build_end = DROP * BAR - BEAT
for k in range(6):
    add("drums", KICK, BAR + k * BEAT / 2, gain=0.55 + 0.07 * k)
snare_roll(BAR, build_end - BAR, gain=0.5)
add("fx", riser(build_end - BAR), BAR, gain=0.4, reverb=0.3)
for k in range(12):  # Am のコードを 16 分で刻みながらフィルターを開ける
    notes = chords[3][0]
    add("pad", stab(notes, STEP * 0.8, 800 + 400 * k), BAR + k * STEP, gain=0.25 + 0.02 * k)

# ---- 本編 ----

stab_steps = [0, 3, 6, 10, 12]  # コードを刻むところ（16 分音符）
for bar in range(DROP, END):
    start = bar * BAR
    notes, root = chords[bar % 4]
    fill = (bar + 1) in SCENES  # 次の小節で場面が変わる
    big_fill = (bar + 1) == OUTRO
    section = 0 if bar < 16 else 1 if bar < 33 else 2

    if bar in SCENES or bar == DROP:
        add("drums", crash(), start, gain=0.25, reverb=0.2)

    # ドラム
    for beat in range(4):
        t0 = start + beat * BEAT
        if big_fill and beat == 3:
            continue  # 最後の場面の前は 1 拍止める
        add("drums", KICK, t0, gain=1.0)
        fill_here = (fill and beat >= 2) or big_fill
        if beat in (1, 3) and not fill_here:
            add("drums", CLAP, t0, gain=0.5, reverb=0.2)
            add("drums", SNARE, t0, gain=0.25)
        for k in range(4):
            velocity = [0.55, 0.3, 0.8, 0.3][k]
            add("drums", hat(), t0 + k * STEP, pan=0.25, gain=0.17 * velocity)
        if section >= 1:
            add("drums", hat(open_=True), t0 + BEAT / 2, pan=-0.2, gain=0.08)
        if section == 0 and beat == 3 and not fill_here:
            add("drums", SNARE, t0 + STEP * 3, gain=0.12)  # 小さな装飾音
    if fill and not big_fill:
        for k in range(8):
            add("drums", SNARE, start + 2 * BEAT + k * STEP, gain=0.22 + 0.04 * k, reverb=0.15)
    if big_fill:
        snare_roll(start, BAR - BEAT, gain=0.45)
        add("fx", riser(BAR - BEAT), start, gain=0.35, reverb=0.3)

    # ベース（拍の頭はキックに任せて、残りの 16 分で「ドゥルル」と刻む）
    for beat in range(4):
        if big_fill and beat == 3:
            continue
        for k in (1, 2, 3):
            length = STEP * 0.85
            note = root + (12 if k == 2 else 0)
            f = midi(note)
            b = saw(f, length) * 0.7 + np.sin(2 * np.pi * f / 2 * times(length)) * 0.8
            b = filt(np.tanh(b * 1.8), 900 + 500 * (k == 2)) * adsr(length, 0.003, 0.05, 0.55, 0.02)
            add("bass", b, start + beat * BEAT + k * STEP, gain=0.34)

    # 刻むコードと、うしろで鳴るパッド
    for k in stab_steps:
        if big_fill and k >= 12:
            continue
        add("pad", stab(notes, STEP * 1.6), start + k * STEP, gain=0.3, reverb=0.25, delay=0.15)
    pad = sum(supersaw(midi(note), BAR) for note in notes) / len(notes)
    add("pad", filt(pad, 1800) * adsr(BAR, 0.05, 1.0, 0.8, 0.1), start, gain=0.12, reverb=0.4)

    # メロディ（16 小節目から。33 小節目からは 1 オクターブ上も重ねる）
    if section >= 1 and not big_fill:
        phrase = (bar - 16) % 4
        for step, note, length in melody:
            if step // 16 != phrase:
                continue
            t0 = start + (step % 16) * STEP
            add("lead", lead(note, length * STEP * 0.95), t0, gain=0.2, reverb=0.25, delay=0.35)
            if section >= 2:
                add("lead", lead(note + 12, length * STEP * 0.95), t0, pan=0.15, gain=0.08, reverb=0.3, delay=0.3)

    # きらきらしたアルペジオ（33 小節目から）
    if section >= 2 and not big_fill:
        pattern = [0, 1, 2, 3, 2, 1, 2, 3]
        for k in range(16):
            add("lead", pluck(notes[pattern[k % 8]] + 24), start + k * STEP,
                pan=0.4 if k % 2 else -0.4, gain=0.06, reverb=0.35)

# ドロップと、おわりの場面の頭に大きな「ドン」
add("fx", impact(), DROP * BAR, gain=0.9, reverb=0.4)
add("fx", impact(), OUTRO * BAR, gain=0.8, reverb=0.4)
# 最後の「ジャーン」（Am）
ring = duration - END * BAR
add("drums", KICK, END * BAR, gain=1.0)
add("fx", impact(), END * BAR, gain=0.8, reverb=0.5)
for note in chords[3][0] + [chords[3][0][0] + 12]:
    chord = supersaw(midi(note), ring) * adsr(ring, 0.005, 1.2, 0.3, 0.6)
    add("pad", filt(chord, 4500), END * BAR, pan=(note % 7 - 3) * 0.15, gain=0.13, reverb=0.6)
add("bass", np.sin(2 * np.pi * midi(chords[3][1] - 12) * times(ring)) * adsr(ring, 0.005, 1.0, 0.3, 0.6), END * BAR, gain=0.5)

# ---- 仕上げ ----

# ポンプ感（キックに合わせてコード・パッド・ベースを下げる）
t = np.arange(n) / RATE
pump = 1 - 0.7 * np.exp(-((t - DROP * BAR) % BEAT) / 0.07)
pump = np.where((t >= DROP * BAR) & (t < END * BAR), pump, 1.0)
for name in ["pad", "bass"]:
    bus[name] *= pump

# やまびこ（付点 8 分のディレイ）
gap = int(BEAT * 0.75 * RATE)
echo = filt(echo, 4000)
delayed = np.zeros_like(echo)
for k in range(1, 5):  # 左右交互に返ってくる
    shift = gap * k
    delayed[:, shift:] += echo[::-1 if k % 2 else 1, : n - shift] * 0.5 ** k

# 残響（ノイズを使ったホールの響き）
ir_t = times(2.2)
ir = np.stack([rng.standard_normal(len(ir_t)), rng.standard_normal(len(ir_t))]) * np.exp(-ir_t * 2.8)
ir[:, : int(0.015 * RATE)] = 0
wet = np.stack([fftconvolve(filt(send[c], 300, "high"), ir[c])[:n] for c in range(2)]) * 0.05

mix = sum(bus.values()) + wet + delayed * 0.6
mix = np.stack([filt(mix[c], 28, "high") for c in range(2)])
mix = np.tanh(mix * 1.5) / np.tanh(1.5)  # 軽く飽和させてまとめる
fade = np.clip(t / 0.005, 0, 1) * np.clip((duration - t) / 1.2, 0, 1)
mix *= fade
mix = mix / np.abs(mix).max() * 0.9

raw_path = out_path + ".raw.wav"
with wave.open(raw_path, "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes((mix.T * 32767).astype("<i2").tobytes())

# 音の大きさを -14 LUFS にそろえる
subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", raw_path,
                "-af", "loudnorm=I=-14:TP=-1.5:LRA=11", "-ar", str(RATE), out_path], check=True)
os.remove(raw_path)
print(f"wrote {out_path} ({duration:.1f}s)")
