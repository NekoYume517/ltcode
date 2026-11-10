///|
/// 容器头部字段的**域校验**（LT-A，2026-11-10 对抗审计）。
///
/// ## 缺陷形态（修复前）
///
/// `unpack_container` 把 43 字节头里的 `count` / `payload_len` 当成有符号
/// `Int32` 直接使用，没有任何域校验：
///
/// - `count = 0xFFFFFFFF` 读进 `Int32` 变成 `-1`，`for i = 0; i < count`
///   一次都不执行 —— 300 个完好符号被**静默丢弃**，解码端于是报
///   `INCOMPLETE: need more symbols (missing 100 of 100)`，exit 1。
///   调用方看到的是"数据不够，再给我几个"，而真实原因是"头部说这里有
///   42 亿个符号"。这是**误导性的业务状态**：既不是损坏、也不是用法错误。
/// - `payload_len = 2^32 + 5` 走 `u64 -> Int32` 静默截断成 `5`：解码"成功"
///   但只写出 5 字节原文，其余被 `reassemble` 截掉。
///
/// 两条同源：**头部是外部输入，读进来必须先证明它在域内**。容器的字节
/// 布局是跨版本契约，因此域校验也必须落在 unpack 这一层，而不是让每个
/// 调用方（`decode_verified`、CLI、测试）各自记得去查。

///|
/// 把大端 u32 写进字节数组的指定偏移（测试用；生产侧的写入口是
/// `pack_container`，这里必须绕过它才能构造非法头部）。
fn poke_u32(arr : Array[Byte], off : Int32, v : UInt64) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    let shift = (3 - i) * 8
    arr[off + i] = ((v >> shift) & 0xFFUL).to_int().to_byte()
  }
}

///|
/// 把大端 u64 写进字节数组的指定偏移。
fn poke_u64(arr : Array[Byte], off : Int32, v : UInt64) -> Unit {
  for i = 0; i < 8; i = i + 1 {
    let shift = (7 - i) * 8
    arr[off + i] = ((v >> shift) & 0xFFUL).to_int().to_byte()
  }
}

///|
/// 让 `try` 的错误类型显式落到 `LtError`（直接在 `catch` 里绑 `e` 会拿到
/// 抽象的 `Error`，没法交给 `error_text`）。
fn unpack_outcome_a(data : Bytes) -> String raise LtError {
  let c = unpack_container(data)
  "unpacked count~\{c.symbols.length()} payload_len=\{c.payload_len}"
}

///|
/// 造一个 K、count 指定、symbol_len=4 的完好容器（每符号 4+4 = 8 字节）。
fn healthy_container(k : Int32, count : Int32) -> (SourceBlock, Bytes) {
  let block = sample_block(k, 4)
  let payload = sample_payload(block)
  let enc = match Encoder::new(block, 0x1234UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, count)
  (block, pack_container(block, 0x1234UL, payload, 0.1, 0.5, symbols))
}

///|
/// **核心回归**：`count = 0xFFFFFFFF`。
///
/// 修复前：unpack 成功（`count` 变 `-1`），300 个符号全被丢掉，解码报
/// `Incomplete(missing 100 of 100)`、退出码 1 —— 与"真的只收到 0 个符号"
/// 完全无法区分。
///
/// 修复后：unpack 直接 raise `InvalidHeaderField("count", 4294967295, 0, 300)`，
/// 退出码 3，不再冒充 `INCOMPLETE`。
test "LT-A: count = 0xFFFFFFFF is rejected instead of dropping every symbol" {
  let (_block, packed) = healthy_container(100, 300)
  // 先确认这个容器本身完好（否则下面的断言测的就不是 count 校验）
  let good = unpack_container(packed) catch {
    _ => abort("good container failed")
  }
  inspect(good.symbols.length(), content="300")
  let arr = packed.to_array()
  // 偏移 39..43 是 count
  poke_u32(arr, 39, 0xFFFFFFFFUL)
  let outcome = unpack_outcome_a(Bytes::from_array(arr)) catch {
    InvalidHeaderField(name, value, low, high) => {
      inspect(name, content="count")
      inspect(value, content="4294967295")
      inspect(low, content="0")
      // 剩余 300*8 = 2400 字节，每符号 4+4 = 8 字节 → 上限 300
      inspect(high, content="300")
      "invalid-header"
    }
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="invalid-header")
}

///|
/// 同一族：`count = 0x80000000`（不是 -1，而是 Int32 的最小值）。
///
/// 两种取值都让 `i < count` 一次都不执行，但 `0x80000000` 修复前连
/// "少丢一点"的错觉都给不出 —— 它同样丢光全部符号。
test "LT-A: count = 0x80000000 is rejected too" {
  let (_block, packed) = healthy_container(20, 40)
  let arr = packed.to_array()
  poke_u32(arr, 39, 0x80000000UL)
  let outcome = unpack_outcome_a(Bytes::from_array(arr)) catch {
    InvalidHeaderField(name, value, _, _) => "\{name}=\{value}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="count=2147483648")
}

///|
/// **这条锁定「不再产生误导性的 INCOMPLETE」**：非法 count 必须让
/// 解码这条路走不到，而不是走进去然后报缺 100/100。
///
/// 修复前这里能拿到 `Incomplete(missing=100)`；修复后拿不到任何
/// `DecodeResult` —— unpack 就已经 raise。
test "LT-A: an invalid count never turns into a fake INCOMPLETE" {
  let (_block, packed) = healthy_container(100, 300)
  let arr = packed.to_array()
  poke_u32(arr, 39, 0xFFFFFFFFUL)
  let bad = Bytes::from_array(arr)
  let outcome = try {
    let c = unpack_container(bad)
    let r = decode_verified(c)
    if r.is_complete() {
      "COMPLETE"
    } else {
      "INCOMPLETE missing \{r.missing_indices().length()}"
    }
  } catch {
    e => "raised: \{error_text(e)}"
  }
  assert_true(!outcome.has_prefix("INCOMPLETE"))
  assert_true(!outcome.has_prefix("COMPLETE"))
  assert_true(outcome.has_prefix("raised: "))
  // 措辞必须点名 count，而不是"truncated"（后者会让调用方去重传）
  assert_true(outcome.contains("count"))
}

///|
/// `payload_len` 是 u64，读进 `Int32` 会**静默截断**：`2^32 + 5` 变 `5`，
/// 于是解码"成功"写出 5 字节。
///
/// 域校验：`payload_len` 不得超过 `K × symbol_len`（原文切块后至多这么长），
/// 也不得超过 `Int32` 正数上限（`reassemble` 与 `Container.payload_len`
/// 都是有符号 Int32）。
test "LT-A: payload_len above K*symbol_len is rejected, not truncated" {
  let (_block, packed) = healthy_container(100, 300)
  // 偏移 23..31 是 payload_len（u64）
  let arr = packed.to_array()
  poke_u64(arr, 23, 4294967301UL)
  let outcome = unpack_outcome_a(Bytes::from_array(arr)) catch {
    InvalidHeaderField(name, value, _, high) => "\{name}=\{value}/\{high}"
    e => "other: \{error_text(e)}"
  }
  // K=100, symbol_len=4 → 上限 400
  inspect(outcome, content="payload_len=4294967301/400")
}

///|
/// 上界同时受 `Int32` 正数上限约束的那一侧：`K × symbol_len` 本身超过
/// 2^31 时，上界必须被钳到 2147483647，而不是让 `payload_len` 落到一个
/// 转 `Int32` 会变负的值。
///
/// 手工拼头部：`pack_container` 写不出这种组合（它只写自洽的字段），
/// 而这条要的正是「每个字段都还在自己域内、但组合起来不自洽」的头部。
/// K = 1<<20（域内上限）、symbol_len = 2049（小于文件长度 4096，域内），
/// 乘积 1048576 × 2049 = 2148532224 > 2^31。
test "LT-A: payload_len upper bound is clamped to the Int32 range" {
  let arr : Array[Byte] = []
  for i = 0; i < 4096; i = i + 1 {
    arr.push(b'\x00')
  }
  arr[0] = b'L'
  arr[1] = b'T'
  arr[2] = b'C'
  arr[3] = b'2'
  arr[4] = container_version.to_byte()
  arr[5] = b'\x0A' // c_q     = 10 → c     = 0.10
  arr[6] = b'\x32' // delta_q = 50 → delta = 0.50
  poke_u32(arr, 7, 1048576UL)
  poke_u64(arr, 11, 1UL)
  poke_u32(arr, 19, 2049UL)
  poke_u64(arr, 23, 2147483648UL)
  poke_u64(arr, 31, 0UL)
  poke_u32(arr, 39, 0UL)
  let outcome = unpack_outcome_a(Bytes::from_array(arr)) catch {
    InvalidHeaderField(name, value, _, high) => "\{name}=\{value}/\{high}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="payload_len=2147483648/2147483647")
}

///|
/// 校验不能误伤：完好的容器、合法的边界值必须继续通过。
///
/// - `count` 恰好等于剩余字节能容纳的符号数（满载容器）
/// - `payload_len == K × symbol_len`（没有补零）
/// - `count == 0`（README / `container_test.mbt` 锁定的合法下界）
/// - `payload_len == 0`（容器格式允许，encode 侧的 `EmptySource` 才拒绝）
test "LT-A: the new header checks do not reject legitimate containers" {
  let block = sample_block(4, 2)
  let payload = sample_payload(block)
  let symbols : Array[Symbol] = [
    Symbol::{ index: 0, data: b"\x01\x02", },
    Symbol::{ index: 1, data: b"\x03\x04", },
    Symbol::{ index: 2, data: b"\x05\x06", },
  ]
  let packed = pack_container(block, 5UL, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch {
    _ => abort("full container rejected")
  }
  inspect(c.symbols.length(), content="3")
  inspect(c.payload_len, content="8")
  inspect(c.k, content="4")
  // 零符号容器
  let zero = pack_container(block, 5UL, payload, 0.1, 0.5, [])
  let zc = unpack_container(zero) catch {
    _ => abort("zero container rejected")
  }
  inspect(zc.symbols.length(), content="0")
  inspect(zc.payload_len, content="8")
  // payload_len 的合法下界 0
  let arr = packed.to_array()
  poke_u64(arr, 23, 0UL)
  let pc = unpack_container(Bytes::from_array(arr)) catch {
    _ => abort("payload_len = 0 rejected")
  }
  inspect(pc.payload_len, content="0")
}

///|
/// 新变体的人读文本必须**点名到字段并带上实际值** ——
/// 只说"容器坏了"等于把用户推回"到底哪个字段错了"。
test "LT-A: error_text names the offending header field and its value" {
  let msg = error_text(InvalidHeaderField("count", 4294967295UL, 0UL, 300UL))
  assert_true(msg.contains("count"))
  assert_true(msg.contains("4294967295"))
  assert_true(msg.contains("300"))
  // 不能借用别的变体的措辞，否则 CLI 输出会把"头部非法"说成"数据不足"
  assert_true(!msg.contains("truncated"))
  assert_true(!msg.contains("empty source"))
  assert_true(!msg.contains("checksum"))
  // 下界方向（同一个变体也负责"K 低于 1"那种情形，见 LT-G）
  let low = error_text(InvalidHeaderField("K", 0UL, 1UL, 1048576UL))
  assert_true(low.contains("below the minimum 1"))
}
