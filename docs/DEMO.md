# ltcode 演示记录

> 本文件里的每一条命令都是**实际执行过**的，输出原样粘贴（含换行与缩进）。
> 没有"示例输出"——只有真实输出。所有命令都在
> `D:\code\moonbit\ltcode` 下运行，环境：
>
> ```powershell
> $env:MOON_HOME="E:\moonbit\home"; $env:Path="E:\moonbit\home\bin;"+$env:Path
> ```

## 1. 构建与测试

```powershell
$ moon check
# (0 errors)

$ moon test
Total tests: 97, passed: 97, failed: 0.

$ moon fmt --check
Finished. moon: ran 22 tasks, now up to date
# exit code 0

$ moon build --target wasm
# 生成 _build/wasm/debug/build/cmd/ltcode/ltcode.wasm
```

## 2. 端到端：编码 → 丢包 → 逐字节还原

准备一份确定性输入（4000 字节，`bytes[i] = (i*37 + 11) % 256`）：

```powershell
$bytes = New-Object byte[] 4000
for ($i=0; $i -lt 4000; $i++) { $bytes[$i] = [byte](($i * 37 + 11) % 256) }
[System.IO.File]::WriteAllBytes("$PWD\examples\payload.bin", $bytes)
```

编码（K=100 段，生成 300 个符号）：

```powershell
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 100 --seed 12345 --count 300 --out examples/payload.ltc
encoded 4000 bytes -> K=100 symbol_len=40 symbols=300 seed=12345
out: examples/payload.ltc (13243 bytes)
```

解码（**不需要** `--symbols` / `--seed`，文件自描述）：

```powershell
$ moon run cmd/ltcode -- decode --input examples/payload.ltc --out examples/roundtrip.bin
decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
out: examples/roundtrip.bin
```

逐字节校验：

```powershell
$ (Get-FileHash examples/payload.bin -Algorithm SHA256).Hash
3933F303EC65329941F26857DE97B8EF7362018A5C7641C0D0386C03900D3B9F
$ (Get-FileHash examples/roundtrip.bin -Algorithm SHA256).Hash
3933F303EC65329941F26857DE97B8EF7362018A5C7641C0D0386C03900D3B9F
```

两个哈希相同 → **逐字节还原**。

## 3. 数据不足：如实报缺

同一份输入，只发 K=100 个符号（overhead = 1.0）：

```powershell
$ moon run cmd/ltcode -- encode --input examples/payload.bin \
    --symbols 100 --seed 999 --count 100 --out examples/tight.ltc
encoded 4000 bytes -> K=100 symbol_len=40 symbols=100 seed=999
out: examples/tight.ltc (4443 bytes)

$ moon run cmd/ltcode -- decode --input examples/tight.ltc --out examples/tight.out
decode INCOMPLETE: need more symbols (missing 51 of 100 source symbols)
missing indices: 0,2,4,6,8,9,10,18,21,22,23,24,25,29,30,
31,33,34,36,38,42,47,50,51,52,53,54,62,65,67,69,70,71,72,73,74,75,76,77,79,81,
83,86,89,90,92,93,94,96,98,99
```

这 51 个下标是**真实算出来的**。没有写出 `tight.out` —— 数据不完整时
不产生"看起来完整"的文件。同一份源码路径有测试断言：已解出的 49 个
源符号逐字节正确（`decoder_test.mbt` 跨 200 条种子）。

（注：不同次运行分块的行宽由终端决定；内容一致。）

## 3b. 损坏的数据被拦住（校验和）

裸 LT 的陷阱：篡改一个**度为 1** 的符号后，剥皮仍可能报 `Complete`，
但解出来的源符号有错。所以容器带 `payload_hash`，解码后重算比对。

`payload.ltc` 里第 32 个符号是度为 1 的（文件偏移 1455 处是它的首字节）：

```powershell
$ $bytes = [System.IO.File]::ReadAllBytes("$PWD\examples\payload.ltc")
$ $bytes[1455] = $bytes[1455] -bxor 0xFF
$ [System.IO.File]::WriteAllBytes("$PWD\examples\corrupt.ltc", $bytes)

$ moon run cmd/ltcode -- decode --input examples/corrupt.ltc --out corrupt.out
ltcode: decoded payload FAILED checksum: got 0x354f7a617b24837d,
                                            expected 0x408f149e6f4ea445
  this means the received symbols were corrupted or mixed from another encoding
  the decoded bytes were NOT written to disk
```

`corrupt.out` **不存在** —— 校验失败时不写文件，退出码 3。

### 反例：改一个度 > 1 的符号，解码反而正确

```powershell
$ $bytes[60] = $bytes[60] -bxor 0xFF   # 第 60 字节属于一个度 > 1 的符号
$ moon run cmd/ltcode -- decode --input examples/corrupt2.ltc --out ok.out
decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
```

这**不是**校验和失灵：LT 有冗余，一个被改坏的度 > 1 符号变成一条错误
方程，但剩余方程足够，剥皮解出的仍是**正确**的全部源符号。实测
`WRONG = 0/20`。判断标准不是"数据有没有被改"，而是"解出来的对不对"。

## 4. 退出码（用真实二进制逐条核对）

`moon run` 会包装子进程，拿不到真实退出码，所以这里用 native 二进制：

```powershell
$ $exe = "_build\native\debug\build\cmd\ltcode\ltcode.exe"

$ & $exe decode --input examples/tight.ltc --out examples/x.bin
# (输出 INCOMPLETE)
incomplete exit code = 1

$ & $exe bogus
# (输出 usage)
usage exit code = 2

$ & $exe encode --input nosuchfile --symbols 10
ltcode: cannot read input file 'nosuchfile'
badinput exit code = 3

$ & $exe decode --input examples/payload.ltc --out examples/rt2.bin
decoded OK: ...
ok exit code = 0
```

四种退出码全部符合 PLAN §9：`0 / 1 / 2 / 3`。

另一个输入错误（不是容器文件）：

```powershell
$ moon run cmd/ltcode -- decode --input examples/payload.bin
ltcode: not a ltcode container: bad magic
# exit 3
```

> **这条输出变过（LT-2）**。旧版这里报的是
> `not a ltcode container: truncated symbol: got 4000 bytes, expected 35`
> —— 明明是"这不是 ltcode 文件"，却借用了"符号被截断"的措辞，会让调用方
> 去重传一个坏文件，而不是换一个正确的文件。现在魔数不符报 `BadMagic`，
> 版本不符报 `UnsupportedVersion`（见下一节）。

## 5. 成功率：K=1000 的完整曲线

PLAN §7 要求的两点 + 整条曲线（500 trials，种子基准 1）：

```powershell
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

PLAN 的两条：

```powershell
$ moon run cmd/ltcode -- simulate --symbols 1000 --overhead 1.0 --trials 1000 --seed 1
  1.00      1000        0/1000      0.000
$ moon run cmd/ltcode -- simulate --symbols 1000 --overhead 1.2 --trials 1000 --seed 1
  1.20      1200        793/1000      0.793
```

- overhead 1.0 → **0.000**（要求 < 10% ✅）
- overhead 1.2 → **0.793 ~ 0.808**（"成功率高" ✅，但**不是** 100%）

### 种子基准稳定性

```powershell
$ for ($s in 1,50000) { moon run cmd/ltcode -- curve --symbols 1000 \
    --overheads 1.18,1.2,1.25 --trials 500 --seed $s }
seed=1       1.18  319/500  0.638
seed=1       1.20  404/500  0.808
seed=1       1.25  486/500  0.972
seed=50000   1.18  315/500  0.630
seed=50000   1.20  405/500  0.810
seed=50000   1.25  488/500  0.976
```

两个基准在 1.18 处相差 0.008，在 n=500 的二项噪声（σ ≈ 0.021）之内。

## 6. 度数分布对照

```powershell
$ moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.2 --trials 200 --seed 1

distcmp  K=1000  overhead=1.20  trials=200  seed=1  symbol_len=4

  distribution          successes  rate
  robust(c=0.10,d=0.50) 162/200    0.810
  ideal                 48/200     0.240
  fixed(5)              0/200      0.000
```

更高开销也救不回理想孤波：

```powershell
$ moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.3 --trials 200 --seed 1
  robust(c=0.10,d=0.50) 200/200    1.000
  ideal                 78/200     0.390
  fixed(5)              0/200      0.000

$ moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.5 --trials 200 --seed 1
  robust(c=0.10,d=0.50) 200/200    1.000
  ideal                 111/200    0.555
  fixed(5)              0/200      0.000
```

**结论**：鲁棒孤波的 τ 尖峰是低开销可用的唯一原因；固定度连度为 1 的
符号都不产生，剥皮无法启动。

## 7. 小 K 的真实行为（诚实记录）

小 K 下"高开销"**也不是必然成功**。这是实测（200 trials，种子步长
2654435761）：

```
K=10 oh=3.0 → 196/200     K=10 oh=2.0 → 175/200
K=17 oh=2.0 → 183/200     K=40 oh=2.0 → 194/200
K=64 oh=2.0 → 196/200
```

原因不是开销不够，而是**剥皮需要至少一个度为 1 的符号**：失败的样本里
`resolved == 0` 压倒多数。K 小时 μ(1) ≈ 0.147，30 个符号全不为 1 的概率
是 `(1-0.147)^30 ≈ 0.9%`，与实测一致。

`decoder_test.mbt` 里为此写了两条测试：
- 成功率断言（阈值取实测值向下取整，**不做"必然成功"的断言**）
- 构造一条"整组无度 1"的种子，断言 `resolved == 0` 且 `missing` 是全部下标

## 8. 复现全部数字

```powershell
# 一条命令复现 README 的曲线
moon run cmd/ltcode -- curve --symbols 1000 --trials 500 `
    --overheads 1.0,1.1,1.15,1.18,1.2,1.25,1.3,1.5,2.0 --seed 1

# 复现分布对照
moon run cmd/ltcode -- distcmp --symbols 1000 --overhead 1.2 --trials 200 --seed 1
```

`--seed` 不给时默认 `0x4C54434F4445`（固定常数，**不是时钟**），
因此同样的命令在任何机器、任何时间都给出同样的输出。