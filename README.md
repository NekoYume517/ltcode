# ltcode

**Luby Transform 无速率纠删码，MoonBit 实现。**

从 K 个源符号生成**任意多个**编码符号；接收方只要拿到略多于 K 个，
就能还原原始数据。丢掉哪些不重要，补发多少由丢包率决定 —— 这就是
"无速率"（rateless）的含义。

[![MoonBit](https://img.shields.io/badge/MoonBit-0.1.20261102-blueviolet)](https://www.moonbitlang.com/)
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

`encode` 省略 `--out` 时写入 `<input>.ltc`，`decode` 省略时写入
`decoded.bin`；三条度量命令省略 `--trials` 时默认 100，省略
`--symbol-len` 时默认 4。

实测输出：

```
encoded 4000 bytes -> K=100 symbol_len=40 symbols=300 seed=12345
out: examples/payload.ltc (13243 bytes)
decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
out: out.bin
```

`out.bin` 与 `examples/payload.bin` 的 SHA-256 相同（逐字节还原）。

### 参数规则：每个参数都要有名字

所有参数都是显式命名的 `--option value`（或 `--option=value`）形态。
**位置参数与未知选项一律是用法错误**（退出码 2），并且报错回显原始 token：

```
$ ltcode decode --input a.ltc --out b.bin --seedx 999999
ltcode: unknown option '--seedx' for decode; run 'ltcode help' for the accepted options
$ echo $?
2

$ ltcode decode --input a.ltc --out b.bin some-junk
ltcode: unexpected positional argument 'some-junk'; every argument to decode must be a named --option
$ echo $?
2
```

这条规则存在的**理由**不是洁癖：`decode` 的 `--symbols` / `--seed` 是
**可选核对项**。一个笔误的键（`--seed` 写成 `--seedx`）如果被静默忽略，
命令依然会打印 `decoded OK ... (checksum verified)` —— 用户以为核对过了，
其实那个参数根本没被读。多写的 token 去哪了必须当场说清，否则"手动核对"
就变成"看起来核对过"。各子命令接受的键写在 `accepted_keys`
（`cmd/ltcode/main.mbt`），一眼可查。

数据不足时**如实报缺**，并以退出码 1 结束：

```
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 100 --seed 999 --count 100 --out examples/tight.ltc
encoded 4000 bytes -> K=100 symbol_len=40 symbols=100 seed=999
out: examples/tight.ltc (4443 bytes)
note: these 100 symbols cannot recover all 100 source symbols (51 missing); decode will report INCOMPLETE - raise --count (the default is ceil(1.5K)+1)

$ moon run cmd/ltcode -- decode --input examples/tight.ltc --out tight.out
decode INCOMPLETE: need more symbols (missing 51 of 100 source symbols)
missing indices: 0,2,4,6,8,9,10,18,21,22,23,24,25,29,30,31,33,34,36,38,42,47,
50,51,52,53,54,62,65,67,69,70,71,72,73,74,75,76,77,79,81,83,86,89,90,92,93,
94,96,98,99
  note: this container already carries 100 symbols for K=100 yet peeling stalled;
  either more symbols are needed, or its header parameters (c_q/delta_q/K) do not
  match the symbols that were encoded
$ echo $?
1
```

**这 51 个下标是真实算出来的**，不是"看起来差不多"。已解出的 49 个源
符号逐字节正确（有测试跨 200 条种子断言这一点）。

上面 `encode` 的第三行是 2026-11-12 加的**可解性验算**（下一节详述）：它当场
就告诉你"这 100 个符号还差 51 个"，与 `decode` 事后报的数字**逐字一致** ——
但 `encode` 仍然以退出码 0 结束，因为容器本身合法。

### 小 `K` 时默认 `--count` 也可能解不出来（实测数据，2026-11-17 复测）

默认值是 `ceil(1.5K)+1`（`default_count`）。这个倍数对大 `K` 够用（overhead 1.5
在 `K=1000` 下成功率接近 1.0，见上面的曲线），但**小 `K` 例外**：剥皮需要的度 1
符号数量由 `ln(K/δ)·√K` 决定，与 `K` 不成正比，1.5 倍往往凑不够。

实测（`encode` 不给 `--count`，再直接 `decode`；输入 `examples/payload.bin`，
`--seed` 一律取默认值 `0x4C54434F4445`，没有别的参数）：

| K | 默认 symbols | decode 结果 |
|---|---|---|
| 2 | 4 | **INCOMPLETE：缺 2 / 2 个源符号** |
| 4 | 7 | **INCOMPLETE：缺 4 / 4 个源符号** |
| 10 | 16 | **INCOMPLETE：缺 6 / 10 个源符号**（`--seed 3`） |
| 100 | 151 | OK（checksum verified） |

> 这张表在 2026-11-12 首次记录时把 K=2 / K=4 两行写成了「OK」。2026-11-17
> 逐行重跑发现那两行**不可复现**：默认种子下 4 个符号对 K=2 一个度 1 符号都
> 没有（`encode` 自己也会打印 `note: these 4 symbols cannot recover all 2
> source symbols`），K=4 同理。**结论方向不变但比原表更糟**：小 K 的默认
> `--count` 不是「偶尔解不开」，而是 K≤4 时必然解不开。数字以本轮实测为准。

所以小 `K` 请显式给 `--count`（例如 `K=10` 用 40 以上，`K≤4` 用 `4K` 以上）。
这不是编码器缺陷：`encode` 只负责写出合法容器，符号够不够是调用方的选择；
如实报告在 `decode`（exit 1 + 缺失下标）。

**2026-11-12 补**：`encode` 末尾现在会自己试解一次并把结论说出来（下一节），
所以这条不再需要用户先踩一遍才知道。

### `encode` 末尾的可解性验算（best-effort，不是保证）

`encode` 生成完符号后会**用同一个解码器**（`decode_full`，不另写一份剥皮）
试解一次。解得开就一个字都不多说；解不开就多打印一行：

```
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 10 --seed 3 --out k10.ltc
encoded 4000 bytes -> K=10 symbol_len=400 symbols=16 seed=3
out: k10.ltc (6507 bytes)
note: these 16 symbols cannot recover all 10 source symbols (6 missing); decode will report INCOMPLETE - raise --count (the default is ceil(1.5K)+1)

$ moon run cmd/ltcode -- decode --input k10.ltc --out k10.out
decode INCOMPLETE: need more symbols (missing 6 of 10 source symbols)
missing indices: 1,2,5,6,7,8
$ echo $?
1
```

退出码**仍是 0**：容器结构完好、字段自洽，只是符号不够 —— 能不能解开取决于
`--count`，那是调用方的选择。这一行是提示，不是错误；把它做成 exit 2 会把
「先写头部、符号之后再补发」这个 rateless 的自然用法变成不可表达。
（同一条推理见上一节 `--count 0`。）

**边界：只在 `--count <= 4096` 时验算。** 验算就是再解一遍，成本与编码同量级
（同一个 `count × 平均度数 × symbol_len` 的 XOR 量），无条件下跑等于让每次
`encode` 慢一倍。`4096` 覆盖了默认 `--count` 在 `K <= 2730` 时的全部取值
（`default_count(2730) = 4096`），也就是本项目「K 至多数千」的全部常规用法。
实测（release native，5~7 次取最小值，`encode` 全程，含写容器）：

| 场景 | 不验算 | 验算 | 差 |
|---|---|---|---|
| 4 KB 输入、`K=100`、`count=300`（本 README 的例子） | 0.053 s | 0.046 s | 噪声内 |
| 1 MB 输入、`K=1000`、默认 1501 | 0.067 s | 0.103 s | +0.036 s |
| 256 KB 输入、`K=100`、`count=4096`（闸门边界） | 0.104 s | 0.211 s | +0.107 s |
| 4 KB 输入、`K=2730`、默认 4096（闸门边界） | 0.046 s | 0.088 s | +0.042 s |
| 64 KB 输入、`K=10`、`count=4096`（闸门边界的极端形态） | 0.181 s | 0.358 s | +0.177 s |
| 4 KB 输入、`K=4000`、默认 6001（**超阈值，跳过**） | 0.053 s | 0.051 s | 0（真的没跑） |

也就是说闸门内的最坏情况是**再花一遍编码的钱**（≈2×），而常规规模下这一行
提示的价格在 10 ms 以内。超阈值时验算**完全不跑**，退出码与 stdout 都与
修复前逐字相同。

**这是 best-effort，不是保证**：没有打印那一行 **不等于**这份容器一定能解。
两件事都可能发生：

1. `--count > 4096` 时根本不验算（闸门）；
2. 验算只回答「**这批**符号够不够」，不回答「这个 `--count` 够不够」——
   同一个 `count` 换 `--seed` 就可能从 Complete 变成 Incomplete（这正是
   上面那张小 K 表的由来：`K=10` + 默认 16 符号，默认种子能解、`--seed 3`
   解不出）。

`help` 里也有同一句话，免得有人把「没提示」读成「已验证」。

### `--count 0` 的语义：产出无符号容器，解码必然失败

`--count` 的下界是 **0**，不是 1。`encode --count 0` 是**合法**调用，
它写出的容器结构完好（43 字节头部、K / seed / symbol_len / payload_len /
哈希/校验和都齐），但 `count = 0` —— 一个编码符号都没有：

```
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 10 --count 0 --out zero.ltc
encoded 4000 bytes -> K=10 symbol_len=400 symbols=0 seed=...
out: zero.ltc (43 bytes)
note: --count 0 wrote a symbol-free container; decode will always report INCOMPLETE

$ moon run cmd/ltcode -- decode --input zero.ltc --out zero.out
decode INCOMPLETE: need more symbols (missing 10 of 10 source symbols)
missing indices: 0,1,2,3,4,5,6,7,8,9
$ echo $?
1
```

**这个容器只能解码失败**，而且失败方式是如实的 `Incomplete`（缺全部 K 个
源符号），退出码 1 —— 不是损坏、不是错误、不是"看起来成功的文件"。

> 上面这段输出**曾经是假的**（2026-11-11 审计修掉）：解码端把 `symbol_len`
> 的上界取成了「整个文件的长度」，零符号容器只有 43 字节头部，于是
> `symbol_len > 43` 的合法头部全被判死 —— 对 4000 字节的 payload 就是
> **K <= 93**，恰好覆盖这个特性的全部实际用法。当时同样的命令得到的是
> `not a ltcode container: symbol_len=400 exceeds the maximum 43`、退出码 3。
> 上界现在只由字段自身的域决定（`count` 那边用剩余字节数卡分配），
> `--count 0` 对任意 K 都按本节描述工作；回归见
> `count_zero_symbol_len_test.mbt`。

为什么保留而不改成退出码 2：

- `0` 是一个**良定义的下界**，不是"非法输入"的近似写法。
  `Encoder::symbols(first_index, 0)` 本来就返回空数组（`encoder_test.mbt`
  锁定），容器格式对 `count = 0` 也没有任何矛盾 —— 它只是声明"这批符号
  我一个都没带来"。
- 拒绝它会把一个**可表达**的请求变成不可表达：先写头部（K、seed、
  payload_len、哈希都已经定下来），符号之后再按需生成/补发。这正是
  rateless 编码的自然用法，而"再要几个符号就行"的补发路径本来就要
  靠 `index` 递增，不需要先知道总数。
- 真正需要防的是**误以为它可用**。这一点用产出侧的
  `note: --count 0 wrote a symbol-free container; decode will always report
  INCOMPLETE` 明说，加上面这条 README 与 `container_test.mbt` 的
  「zero-symbol container parses but always decodes Incomplete」锁定，
  比让命令行直接拒绝更干净 —— 拒绝会让"我想先生成头部"这个正当需求
  只能靠绕过 CLI 实现。

`--count 0` 时**不做**上一节那个可解性验算（0 个符号必然解不出，再说一遍只是
噪音）：两条 `note:` 不会同时出现，这里打印的就是这一条。

### 损坏的数据会被拦住，而不是变成"看起来成功的文件"

裸 LT 有一个不直观的陷阱：收到的符号之间互相矛盾时（传输中被改了一个
字节），剥皮**仍然可能跑完并报成功**，而解出来的若干源符号是错的。
实测：把**一个度为 1 的符号**改掉一个字节，K=20 的用例返回 `Complete`，
而 20 个源符号里有 **7 个是错的**。

原因在算法本身：度为 1 的符号，它的累积值**就是**那个源符号，没有任何
冗余可以交叉验证。方程组自己发现不了这件事。

所以容器头里带一个 `payload_hash`（FNV-1a 64），解码后重算并比对，
不一致就拒绝输出。

`examples/corrupt.ltc` **不是仓库里的文件**：仓库只提交 `payload.bin` /
`payload.ltc` / `tight.ltc` 与往返产物。损坏样本是演示时**手工生成**的
中间产物 —— 复制 `payload.ltc`，按下面的 `ReadAllBytes` / 翻转 / 写回三行
把第 32 个符号（度为 1）的首字节改掉，写到临时路径即可复现：

```powershell
$ $bytes = [System.IO.File]::ReadAllBytes("$PWD\examples\payload.ltc")
$ $bytes[1455] = $bytes[1455] -bxor 0xFF      # 第 32 个符号的首字节
$ [System.IO.File]::WriteAllBytes("$PWD\expr\corrupt.ltc", $bytes)

$ moon run cmd/ltcode -- decode --input expr/corrupt.ltc --out corrupt.out
ltcode: decoded payload FAILED checksum: got 0x354f7a617b24837d, expected 0x408f149e6f4ea445
  this means the received symbols were corrupted or mixed from another encoding
  the decoded bytes were NOT written to disk
$ echo $?
3
```

完整的生成步骤（含偏移为什么是 1455）见 [docs/DEMO.md](docs/DEMO.md) §3b。

**文件没有写出来。** 这是 PLAN §9 "成功时逐字节校验"的实现：校验不是
可选的后处理，而是 `Complete` 的定义的一部分。

> 注意这个哈希**不抗主动攻击** —— 它能抓住意外损坏（改字节、截断、
> 把内容与头部字段错配），抓不住有人故意构造碰撞。本项目不声称防水篡改。
>
> **「拼接错误」不是这个哈希负责的**：把一个容器的头与另一个容器的符号体
> 拼在一起，`payload_hash` 有可能仍然通过（解出来的 payload 也许就是对的
> —— 符号完好的话）。这类「文件结构不自洽」由容器层负责：读完 `count` 个
> 符号后必须**恰好**用完文件，否则报
> `trailing bytes after the last symbol: N bytes consumed of M`、退出码 3。
> 追加垃圾、`cat a.ltc b.ltc`、把 `count` 改小，三条都实测被这一步拦住
> （`src/trailing_guard_test.mbt` 锁定）。两层各管一件事：哈希管**内容**，
> 尾部校验管**结构**。

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

`--symbols` 的上界与 `encode` 完全同域（`max_source_symbols()` = `1 << 20`），
越界是**用法错误**（exit 2）而不是「输入非法」（exit 3）：

```
$ ltcode simulate --symbols 1048577 --overhead 1.0 --trials 1
ltcode: --symbols must be <= 1048576 (got 1048577); the degree distribution table
        and the decoding CSR index are O(K), so measure at a smaller K and raise
        --overhead instead
$ echo $?
2
```

同一个值在 `encode` 上一直是 exit 2（LT-K），度量侧漏到 2026-11-13 才补上
（LT2）：那时它会一路跑到库里的 `random_sources(k)`，报
`simulate failed: source too large: K=...` —— 一个关于「源文件」的错误，
而这三条度量命令根本不读文件。另外 `--overhead` 的守卫量是
`K × overhead`（收到的符号数），K 本身**没有**量级界，所以
「极小 overhead + 巨大 K」会绕开它，那才是这条域上界真正要紧的地方。

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
moon test             # 188 tests, all pass
moon fmt --check      # clean
moon build --target wasm
```

测试分布（188 条，按 `^test "` 计数）：

| 文件 | 条数 | 覆盖 |
|---|---|---|
| `gf256_test.mbt` | 9 | 65536 对乘法全量对照、255 次求逆、FIPS-197 锚点、结合律抽样 |
| `gf256_domain_test.mbt` | 8 | 输入按元素截断到低 8 位、负指数归一、大指数不溢出（2026-11-10 审计） |
| `rng_test.mbt` | 9 | 前 16 输出锁定、拒绝采样阈值、取模偏差可见性 |
| `distribution_test.mbt` | 13 | 归一化 1e-12、τ 尖峰、3σ 采样、整条 pmf、K=1/2/3 |
| `tau_r0_test.mbt` | 4 | τ 尖峰在 r=0（K=1、δ=1.0）取 0 而非 NaN；K=1/δ=1 的分布、往返与容器（2026-11-15 审计） |
| `quantize_image_test.mbt` | 10 | 非网格参数的量化归一往返、量化像缝隙的行为锁定、全像恒等（2026-11-15 审计） |
| `encoder_test.mbt` | 10 | 确定性、无放回、20 个子集穷举、O(d) 内存、K=1 退化 |
| `decoder_test.mbt` | 13 | 诚实报缺、跨 200 种子诚实性、无度 1 结构断言、操作计数线性 |
| `metrics_test.mbt` | 12 | 格式化、可复现、分布对照方向、零试验不产生 NaN |
| `metric_guard_test.mbt` | 8 | `--trials`/`--overhead`/`--symbol-len` 量级守卫（2026-11-10 审计） |
| `metric_symbols_bound_wbtest.mbt` | 3 | 度量侧 `--symbols` 的域上界 + 否决顺序 + 另三条量级守卫未回退（2026-11-13 审计） |
| `metric_work_guard_wbtest.mbt` | 6 | `trials × max(K,received)` 工作预算；零/小数 received、上界±1 与全部文档锚点（2026-11-16 审计） |
| `container_test.mbt` | 11 | 头部逐字节锁定、往返、截断拒绝、`BadMagic`/`UnsupportedVersion`、零符号容器、自描述、校验和拦篡改 |
| `header_guard_test.mbt` | 10 | `count`/`payload_len` 无符号域校验、`symbol_len` 回绕防护（2026-11-10 审计）、`c_q`/`delta_q` 域校验（2026-11-13 审计） |
| `count_zero_symbol_len_test.mbt` | 4 | 零符号容器的 `symbol_len` 域（43 字节边界两侧）、K=93/94、`symbol_len` 与 payload 长短无关（2026-11-11 审计） |
| `trailing_guard_test.mbt` | 5 | 尾部多余字节（追加垃圾 / 拼接容器）必须报错 |
| `k_field_test.mbt` | 6 | 头部 K 字段域校验与独立文案 |
| `overflow_guard_test.mbt` | 3 | 头部字段越界走分类错误而非 panic |
| `verified_test.mbt` | 3 | 完好容器通过校验、篡改必 raise `CorruptionDetected` |
| `symbol_test.mbt` | 3 | `reassemble` 逐字节还原、按 `payload_len` 截零、空输入不 panic |
| `inconsistent_test.mbt` | 2 | `DecodeStats.inconsistent` 结构性恒 0 的护栏 |
| `cli_test.mbt` | 14 | 参数三态（缺席/合法/非法）、`--seed` 显式 `0x`、负值与溢出拒绝、非有限值拒绝、overhead 严格拒绝、退出码语义判别 |
| `unknown_flag_test.mbt` | 7 | 未知 `--flag` 与位置参数报用法错误 |
| `default_count_test.mbt` | 5 | 默认 `--count` 是 `ceil(1.5K)+1`（含奇数 K 的分水岭）、触顶时说明「默认值超限」 |
| `symbols_bound_test.mbt` | 1 | `--symbols` 上界在用法层判、文案点名 `--symbols` 而非输入文件（2026-11-11 审计） |
| `count_guard_test.mbt` | 1 | `--count` 上限常量与语义（LC-1） |
| `usage_coverage_wbtest.mbt` | 2 | `help` 与 `accepted_keys` 必须互相投影（2026-11-12 审计） |
| `solvability_note_wbtest.mbt` | 6 | `encode` 末尾可解性验算：解不出必说、解得出逐字不变、闸门 `count <= 4096`、`--count 0` 优先（2026-11-12 followup） |

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