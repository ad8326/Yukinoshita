#!/usr/bin/env python3
"""生成雪景屏保氛围音乐：轻风底噪 + 柔和五声音阶钢琴点缀，无缝循环。
纯 Python 实现（不依赖 numpy），输出 16-bit WAV，之后用 afconvert 转 AAC。
"""
import array
import math
import random
import struct
import sys
import wave

SR = 32000          # 采样率：氛围乐足够
DUR = 60.0          # 时长（秒）
N = int(SR * DUR)
LOOP_FADE = 2.0     # 循环交叉淡化秒数，保证首尾无缝

random.seed(42)     # 固定种子，可复现

buf = array.array("d", [0.0]) * N

# ---------- 1. 轻风底噪：白噪 -> 一阶低通 -> 呼吸式慢调幅 ----------
wind_lp = 0.0
breath_period = 23.0  # 风的强弱起伏周期（秒）
for i in range(N):
    t = i / SR
    noise = random.uniform(-1.0, 1.0)
    wind_lp += 0.035 * (noise - wind_lp)          # 低通，等效几百 Hz 截止
    # 慢速调幅 + 轻微不规则抖动
    lfo = 0.55 + 0.45 * math.sin(2 * math.pi * t / breath_period)
    gust = 1.0 + 0.15 * math.sin(2 * math.pi * t / 7.3 + 1.2)
    buf[i] += wind_lp * lfo * gust * 0.55

# ---------- 2. 柔和钢琴点缀：C 大调五声音阶，慢速稀疏音符 ----------
# C 大调五声音阶：C D E G A
PENTA = [261.63, 293.66, 329.63, 392.00, 440.00]
NOTES = [f / 2 for f in PENTA] + PENTA + [f * 2 for f in PENTA[:3]]  # 跨两个八度

t_cursor = 1.5
while t_cursor < DUR - 8.0:                        # 尾段不留长音，避免循环切断
    freq = random.choice(NOTES)
    note_dur = random.uniform(4.0, 7.0)
    vel = random.uniform(0.10, 0.18)               # 轻触键力度
    start = int(t_cursor * SR)
    length = min(int(note_dur * SR), N - start)
    attack = int(0.12 * SR)
    # 三组谐波模拟音色，高次谐波衰减更快
    harmonics = [(1, 1.0, 1.4), (2, 0.35, 2.2), (3, 0.12, 3.5)]
    detune = 1.0 + random.uniform(-0.0015, 0.0015)  # 轻微失谐，更"真"
    for j in range(length):
        tj = j / SR
        # 包络：软起音 + 指数衰减
        env = min(tj / (attack / SR), 1.0) * math.exp(-2.1 * tj)
        s = 0.0
        for mult, amp, decay in harmonics:
            s += amp * math.sin(2 * math.pi * freq * mult * detune * tj) * math.exp(-decay * tj)
        buf[start + j] += s * env * vel
    t_cursor += random.uniform(2.5, 5.5)           # 稀疏点缀

# ---------- 3. 简易混响：两次延迟叠加 ----------
echo1 = int(0.31 * SR)
echo2 = int(0.47 * SR)
wet = array.array("d", [0.0]) * N
for i in range(N):
    v = buf[i]
    if i >= echo1:
        v += buf[i - echo1] * 0.28
    if i >= echo2:
        v += buf[i - echo2] * 0.16
    wet[i] = v

# ---------- 4. 循环无缝处理：尾部 2s 与头部 2s 交叉淡化 ----------
fade = int(LOOP_FADE * SR)
for i in range(fade):
    k = i / fade
    wet[i] = wet[i] * k + wet[N - fade + i] * (1 - k)
for i in range(N - fade, N):
    wet[i] = 0.0                                   # 尾部内容已折回头部，直接清零防重复

# ---------- 5. 归一化到温和电平并写出 WAV ----------
peak = max(abs(v) for v in wet)
gain = 0.45 / peak
with wave.open(sys.argv[1] if len(sys.argv) > 1 else "ambient.wav", "w") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(SR)
    frames = array.array("h", (int(max(-1.0, min(1.0, v * gain)) * 32767) for v in wet))
    f.writeframes(frames.tobytes())

print("done")
