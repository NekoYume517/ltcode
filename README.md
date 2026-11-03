# ltcode

**Luby Transform 无速率纠删码，MoonBit 实现。**

从 K 个源符号生成**任意多个**编码符号；接收方只要拿到略多于 K 个，
就能还原原始数据。丢掉哪些不重要，补发多少由丢包率决定 —— 这就是
"无速率"（rateless）的含义。

[![MoonBit](https://img.shields.io/badge/MoonBit-0.1.20261016-blueviolet)](https://www.moonbitlang.com/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

---

## 为什么

固定码率的纠删码（Reed-Solomon）要求**先知道**丢多少：你要预先决定
"发 N 个、能容忍丢 M 个"。在广播/多播、卫星链路、或者接收方数量不定
的场景里，这个前提不成立 —— 你不知道谁会丢多少。

LT 码把这件事反过来：**发多少由接收方决定**。接收方说"我还差 7 个"，
发送方就多给 7 个（其实是多给几个，见下面的开销数据）。中间不需要
重传协商，不需要反馈信道知道具体丢了哪些包。

代价是解码端的复杂度：LT 用**剥皮**（peeling）而不是线性代数。

## 这个实现能给你什么

| 能力 | 状态 |
|---|---|
| GF(256) 域运算（AES 多项式 0x11B） | ✅ 65536 对乘法与无表实现全量核对 |
| 确定性 PRNG（xorshift128+ / splitmix64） | ✅ 前 16 输出锁定，拒绝采样无偏 |
| 理想孤波 / 鲁棒孤波 / 固定度分布 | ✅ 归一化 1e-12，采样分布 3σ 核对 |
| 确定性编码（任意符号可独立重算） | ✅ 无需 O(K) 内存 |
| 剥皮解码 | ✅ 失败如实报缺，**绝不填充** |
| 成功率度量（可复现） | ✅ 见下表，一条命令即可复现 |
| inactivation + 高斯消元 | ❌ **设计选择**，见"不做什么" |
| Raptor / RaptorQ | ❌ 另一个项目的量级 |

## 实测成功率（这是本项目最重要的数字）

K = 1000，鲁棒孤波 c = 0.1、δ = 0.5，符号长 4 字节，种子基准 1：

```
$ moon run cmd/ltcode -- curve --symbols 1000 --trials 500 \
    --overheads 1.0,1.1,1.15,1.18,1.2,1.25,1.3,1.5,2.0 --seed 1

curve  K=1000  c=0.10  delta=0.50  trials=500  seed=1  symbol_len=4

  overhead  received  successes  rate
  1.00      1000        0/500      0.000
  1.10      1100        0/500      0.000
  1.15      1150        90/500      0.180
  1.18      1180        319/500      0.638
  1.20      1200        404/500      0.808
  1.25      1250        486/500      0.972
  1.30      1300        500/500      1.000
  1.50      1500        500/500      1.000
  2.00      2000        500/500      1.000
```

**PLAN 要求的两条都成立**：

- overhead = 1.0 → **0.000**（< 10% 的要求满足，实际是 0/500）
- overhead = 1.2 → **0.808**（"成功率高"成立，但不是 100%）

> 同一参数在 n=1000 的 `simulate` 下是 **0.793**（793/1000），n=500 的
> `curve` 下是 **0.808**。两个都是实测值，差别是抽样噪声 —— n=500 时
> σ ≈ 0.0176，n=1000 时 σ ≈ 0.0128，0.015 的差约 1.2σ（合并 σ ≈ 0.015）。
> 这里不取平均、也不挑"好看的那个"：两条命令都写在文档里，谁能复现谁验证。

**1.2 处不是 100% 这件事必须说清楚**：它是 LT 的真实性质，不是实现缺陷。
剥皮过程一旦在某一步没有度为 1 的符号就停住，剩余符号无法恢复；
1.2 开销下这种"卡住"的概率就是这么高。

### 种子基准不影响结论

上面的曲线不是"某一条种子运气好"：

```
$ # 同样的参数，换种子基准
seed=1       1.18 → 0.638    1.20 → 0.808    1.25 → 0.972
seed=50000   1.18 → 0.630    1.20 → 0.810    1.25 → 0.976
```

两个基准在 1.18 处的差是 0.008，在 500 次试验的二项噪声
（σ ≈ 0.021）之内。

> **这里踩过一个真实的坑**：早期版本用 `splitmix64(seed ^ index)`
> 派生每个符号的 PRNG，导致**相邻种子的试验高度相关** —— 10 个
> "独立"的 200 次试验块之间标准差是 **0.350**，而二项分布只允许
> **0.034**。当时测出的 overhead=1.2 成功率是 1.000，纯粹是假象。
> 修法见 `docs/implementation.md` 第 5 节，修完后块间标准差 0.029。

## 度数分布到底重不重要

`distcmp` 用**同一 K、同一 overhead、同一串种子**，只换分布：

```
$ moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.2 --trials 200 --seed 1

  distribution          successes  rate
  robust(c=0.10,d=0.50) 162/200    0.810
  ideal                 48/200     0.240
  fixed(5)              0/200      0.000
```

加开销也救不回来：

```
overhead  robust      ideal      fixed(5)
1.20      0.810       0.240      0.000
1.30      1.000       0.390      0.000
1.50      1.000       0.555      0.000
```

- **鲁棒孤波**的 τ 尖峰（`τ(K/R) = R·ln(R/δ)/K`，K=1000 时在第 41 点上）
  是它能在低开销下工作的**唯一原因**。理想孤波没有这一段，1.5 开销
  还只有 55.5%。
- **固定度 5** 是 0.000 —— 它连一个度为 1 的符号都不会产生，剥皮
  根本无法启动。

这就是"τ 不是装饰"的可复现证据。

## 用法

```bash
# 编码：把文件切成 K=100 段，生成 300 个编码符号
moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 100 --seed 12345 --count 300 --out examples/payload.ltc

# 解码：只需要这个文件（头部自描述：K、seed、symbol_len、payload_len）
moon run cmd/ltcode -- decode --input examples/payload.ltc --out out.bin
```

实测输出：

```
encoded 4000 bytes -> K=100 symbol_len=40 symbols=300 seed=12345
out: examples/payload.ltc (13243 bytes)
decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
out: out.bin
```

`out.bin` 与 `examples/payload.bin` 的 SHA-256 相同（逐字节还原）。

数据不足时**如实报缺**，并以退出码 1 结束：

```
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 100 --seed 999 --count 100 --out examples/tight.ltc
encoded 4000 bytes -> K=100 symbol_len=40 symbols=100 seed=999

$ moon run cmd/ltcode -- decode --input examples/tight.ltc --out tight.out
decode INCOMPLETE: need more symbols (missing 51 of 100 source symbols)
missing indices: 0,2,4,6,8,9,10,18,21,22,23,24,25,29,30,31,33,34,36,38,42,47,
50,51,52,53,54,62,65,67,69,70,71,72,73,74,75,76,77,79,81,83,86,89,90,92,93,
94,96,98,99
$ echo $?
1
```

**这 51 个下标是真实算出来的**，不是"看起来差不多"。已解出的 49 个源
符号逐字节正确（有测试跨 200 条种子断言这一点）。

### 损坏的数据会被拦住，而不是变成"看起来成功的文件"

裸 LT 有一个不直观的陷阱：收到的符号之间互相矛盾时（传输中被改了一个
字节），剥皮**仍然可能跑完并报成功**，而解出来的若干源符号是错的。
实测：把**一个度为 1 的符号**改掉一个字节，K=20 的用例返回 `Complete`，
而 20 个源符号里有 **7 个是错的**。

原因在算法本身：度为 1 的符号，它的累积值**就是**那个源符号，没有任何
冗余可以交叉验证。方程组自己发现不了这件事。

所以容器头里带一个 `payload_hash`（FNV-1a 64），解码后重算并比对，
不一致就拒绝输出：

```bash
$ # 把 payload.ltc 里第 32 个符号（度为 1）的第一个字节翻转
$ moon run cmd/ltcode -- decode --input examples/corrupt.ltc --out corrupt.out
ltcode: decoded payload FAILED checksum: got 0x354f7a617b24837d, expected 0x408f149e6f4ea445
  this means the received symbols were corrupted or mixed from another encoding
  the decoded bytes were NOT written to disk
$ echo $?
3
```

**文件没有写出来。** 这是 PLAN §9 "成功时逐字节校验"的实现：校验不是
可选的后处理，而是 `Complete` 的定义的一部分。

> 注意这个哈希**不抗主动攻击** —— 它能抓住意外损坏（改字节、截断、
> 把两批符号混在一起），抓不住有人故意构造碰撞。本项目不声称防水篡改。

### 度量

```bash
# 单点
moon run cmd/ltcode -- simulate --symbols 1000 --overhead 1.2 --trials 1000 --seed 1

# 曲线
moon run cmd/ltcode -- curve --symbols 1000 --overheads 1.0,1.15,1.2,1.3 --trials 500 --seed 1

# 分布对照
moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.2 --trials 200 --seed 1
```

所有命令的 `--seed` 默认是固定常数 `0x4C54434F4445`（不是时钟），
所以同样的命令在任何机器上都给出同样的输出。

## 不做什么（明确的设计选择，不是缺陷）

### 没有 inactivation + 高斯消元

inactivation 的做法是：剥皮卡住时，把阻碍的符号"标记为不参与"，
攒够一批后跑一次 GF(256) 高斯消元。它能把 LT 从"1.2 开销下约 80% 成功"
推到"几乎必成"。

本项目**不做**这一块，理由是：那是独立的一大块实现（高斯消元的正确性、
稀疏性、消元顺序都是独立的验证负担），而本项目的目标是**可证伪的
失败**——卡在哪里就如实报哪里。加上 inactivation 之后，"失败"这个
输出几乎消失，反而失去了度量它的能力。

这不是说 inactivation 不值得做，而是说它属于下一版。

### 没有 Raptor / RaptorQ

Raptor 是 LT + 预编码（LDPC + 高码率 LT）的分层构造。它是工业界真正
在用的方案（3GPP MBMS、RFC 6330），但量级完全不同：需要实现预编码的
稀疏矩阵、多阶段解码、以及比 LT 复杂一个数量级的参数集。本项目只做 LT。

### 一次解码固定 overhead，不做自适应补发

`decode` 拿到多少符号就解多少。真实系统里应该做成"缺多少要多少"的
循环，但那是协议层的事，不是编解码层的事。本项目的 `Incomplete` 返回
真实缺失下标，正是为了让调用方能做这件事。

## 项目结构

```
src/
  gf256.mbt         GF(256) 域运算 + 无表对照实现
  rng.mbt           xorshift128+ / splitmix64 / 拒绝采样
  distribution.mbt  理想孤波、鲁棒孤波、固定度
  symbol.mbt        源块与符号表示
  encoder.mbt       确定性编码（Floyd 无放回抽样）
  decoder.mbt       剥皮解码 + 操作计数
  metrics.mbt       成功率、曲线、分布对照
  container.mbt     自描述文件格式
  error.mbt         错误类型
cmd/ltcode/
  main.mbt          参数解析 + 子命令分发
  cli.mbt           encode / decode / simulate / curve / distcmp
```

## 验证

```bash
moon check            # 0 errors
moon test             # 84 tests, all pass
moon fmt --check      # clean
moon build --target wasm
```

测试分布（84 条，按 `^test "` 计数）：

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `gf256_test.mbt` | 9 | 65536 对乘法全量对照、255 次求逆、FIPS-197 锚点、结合律抽样 |
| `rng_test.mbt` | 9 | 前 16 输出锁定、拒绝采样阈值、取模偏差可见性 |
| `distribution_test.mbt` | 13 | 归一化 1e-12、τ 尖峰、3σ 采样、整条 pmf、K=1/2/3 |
| `encoder_test.mbt` | 10 | 确定性、无放回、20 个子集穷举、O(d) 内存、K=1 退化 |
| `decoder_test.mbt` | 13 | 诚实报缺、跨 200 种子诚实性、无度 1 结构断言、操作计数线性 |
| `metrics_test.mbt` | 12 | 格式化、可复现、分布对照方向、零试验不产生 NaN |
| `container_test.mbt` | 9 | 头部逐字节锁定、往返、截断/魔数/版本拒绝、自描述 |
| `verified_test.mbt` | 3 | 完好容器通过校验、篡改必 raise `CorruptionDetected` |
| `cli_test.mbt` | 6 | 参数解析两种形式、数字拒绝垃圾、overhead 清洗、退出码语义判别 |

详细的方法与踩过的坑见 [docs/implementation.md](docs/implementation.md)，
每个命令的实际运行记录见 [docs/DEMO.md](docs/DEMO.md)，
API 契约见 [API.md](API.md)。

## 背景资料

- M. Luby, *LT Codes*, FOCS 2002 — 理想孤波与鲁棒孤波的定义
- A. Shokrollahi, *Raptor Codes*, 2006 — LT 的预编码扩展（本项目不含）
- FIPS-197 §4.2 — GF(256) 乘法例子 `0x57 · 0x83 = 0xC1`
- S. Vigna, *Further scramblings of Marsaglia's xorshift generators*, 2014
- D. Lea / G. Steele, splitmix64（Java 8 `SplittableRandom` 的混合函数）

## License

Apache-2.0，见 [LICENSE](LICENSE)。