///|
/// 容器 `K` 字段非法（LT-G，2026-11-10 对抗审计）。
///
/// ## 缺陷形态（修复前）
///
/// `K` 在头里是 u32，读进 `Int32` 后 `0x80000000` 变成 `-2147483648`。
/// 这个负值一路走到 `decoder.mbt:125` 的 `if k < 1`，于是 CLI 输出：
///
/// ```
/// $ ltcode decode --input k_neg.ltc --out o.bin
/// ltcode: decode error: empty source: at least one source symbol with a
///         non-zero length is required
/// exit 3
/// ```
///
/// 把一个**头部字段非法**说成「输入为空」。用户据此会去检查自己的源文件
/// 是不是空的 —— 而那个文件根本没参与这次解码（decode 只读容器）。
///
/// 同一族还有另外两个方向会让 `K` 落进"别处的错误"：
/// - `K = 0`：同一个 `EmptySource`，同样误导。
/// - `K` 大于 `max_source_symbols()`（1<<20）：`SourceTooLarge(K, limit)`，
///   文案读起来是"你给的源太大"，而实际是**文件里的 K** 太大。
///
/// ## 修法
///
/// 在 unpack 层（唯一入口）校验 `1 <= K <= max_source_symbols()`，越界报
/// 独立的 `InvalidHeaderField("K", ...)`，文案点名 K 并给出合法范围。这样
/// decoder 的 `k < 1` 分支仍然保留（它是库层对**调用方**的保护），但不再
/// 会被容器读进来的坏值触发。

///|
/// 手工拼一个头部：只改 K，其余字段保持自洽的最小值（零符号容器）。
fn container_with_k(k_field : UInt64) -> Bytes {
  let arr : Array[Byte] = []
  for i = 0; i < 43; i = i + 1 {
    arr.push(b'\x00')
  }
  arr[0] = b'L'
  arr[1] = b'T'
  arr[2] = b'C'
  arr[3] = b'2'
  arr[4] = container_version.to_byte()
  arr[5] = b'\x0A' // c     = 0.10
  arr[6] = b'\x32' // delta = 0.50
  poke_u32_k(arr, 7, k_field)
  for i = 0; i < 8; i = i + 1 {
    arr[11 + i] = b'\x00' // seed = 0
  }
  poke_u32_k(arr, 19, 1UL) // symbol_len = 1
  for i = 0; i < 8; i = i + 1 {
    arr[23 + i] = b'\x00' // payload_len = 0
  }
  for i = 0; i < 8; i = i + 1 {
    arr[31 + i] = b'\x00' // payload_hash = 0
  }
  poke_u32_k(arr, 39, 0UL) // count = 0
  Bytes::from_array(arr)
}

///|
/// 大端写 u32（本文件自用，避免与 header_guard_test 的同名助手冲突 ——
/// 包内顶层函数只能定义一次）。
fn poke_u32_k(arr : Array[Byte], off : Int32, v : UInt64) -> Unit {
  for i = 0; i < 4; i = i + 1 {
    let shift = (3 - i) * 8
    arr[off + i] = ((v >> shift) & 0xFFUL).to_int().to_byte()
  }
}

///|
/// 让 `try` 的错误类型显式落到 `LtError`。
fn unpack_outcome_g(data : Bytes) -> String raise LtError {
  let c = unpack_container(data)
  "unpacked K=\{c.k}"
}

///|
/// **核心回归**：`K = 0x80000000`（变负）必须报 `K` 非法，不是 `EmptySource`。
///
/// 修复前实测：
///     ltcode: decode error: empty source: at least one source symbol with a
///             non-zero length is required
test "LT-G: a negative K field is reported as an invalid header, not empty source" {
  let bad = container_with_k(0x80000000UL)
  let outcome = unpack_outcome_g(bad) catch {
    InvalidHeaderField(name, value, low, high) => {
      inspect(name, content="K")
      inspect(value, content="2147483648")
      inspect(low, content="1")
      inspect(high, content="\{max_source_symbols()}")
      "invalid-K"
    }
    e => {
      // 关键：绝不能落到 EmptySource
      let msg = error_text(e)
      assert_true(!msg.contains("empty source"))
      "other: \{msg}"
    }
  }
  inspect(outcome, content="invalid-K")
}

///|
/// `K = 0`：同理，必须报 `K` 非法而不是「输入为空」。
///
/// 注意 `Container` 的下界：K=0 的容器在结构上是"自洽"的（零符号），
/// 但它在语义上不可解码（没有任何源符号可恢复），而 `encode` 侧
/// `SourceBlock::from_bytes` 早就用 `EmptySource` 拒掉了这个输入。
/// 因此 K=0 的容器只可能来自手工构造 —— 报"头部字段非法"比报"输入为空"
/// 更诚实：**没有任何输入是空的**，是文件里的字段越界了。
test "LT-G: K = 0 is reported as an invalid header field, not empty source" {
  let bad = container_with_k(0UL)
  let outcome = unpack_outcome_g(bad) catch {
    InvalidHeaderField(name, value, low, _) => "\{name}=\{value} >= \{low}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="K=0 >= 1")
}

///|
/// `K > max_source_symbols()`：必须报 K 非法，而不是 `SourceTooLarge`。
///
/// `SourceTooLarge(K, limit)` 的文案是 "source too large: K=... exceeds the
/// limit of ..." —— 读起来像"**你**给的源太大"，而这里其实是**文件头部**
/// 声明的 K 越界。两者对调用方的动作指引不同：前者改自己的输入，后者
/// 这个文件根本不是本构建能读的。
test "LT-G: K above the documented limit is reported as an invalid header field" {
  let over = (max_source_symbols() + 1).to_uint64()
  let bad = container_with_k(over)
  let outcome = unpack_outcome_g(bad) catch {
    InvalidHeaderField(name, value, _, high) => "\{name}=\{value} > \{high}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="K=\{over} > \{max_source_symbols()}")
}

///|
/// 边界必须**双向**放行/拒绝：`K = 1` 与 `K = max_source_symbols()` 都是
/// 合法容器（只要其余字段自洽）。
test "LT-G: K = 1 and K = max_source_symbols() are both accepted" {
  let one = container_with_k(1UL)
  let c1 = unpack_container(one) catch { _ => abort("K=1 rejected") }
  inspect(c1.k, content="1")
  let top = container_with_k(max_source_symbols().to_uint64())
  let ct = unpack_container(top) catch { _ => abort("K=max rejected") }
  inspect(ct.k, content="\{max_source_symbols()}")
}

///|
/// 正常编码出来的容器**不受影响**：pack_container 只会写 `1 <= K <= 1<<20`
/// （SourceBlock 构造时就查过），因此这条只是把"没有误伤"固定住。
test "LT-G: containers produced by pack_container are unaffected" {
  let block = sample_block(100, 4)
  let payload = sample_payload(block)
  let enc = match Encoder::new(block, 3UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 300)
  let packed = pack_container(block, 3UL, payload, 0.1, 0.5, symbols)
  let c = unpack_container(packed) catch {
    _ => abort("good container rejected")
  }
  inspect(c.k, content="100")
  inspect(c.symbols.length(), content="300")
}

///|
/// 文案分工：`InvalidHeaderField` 与 `EmptySource` 必须能当场分辨 ——
/// 一个说"文件里的 K 越界"，一个说"输入为空"。两者对调用方的动作指引
/// 完全不同（换文件 vs 补输入），合并会让人查错方向。
test "LT-G: error_text for K keeps the two diagnoses distinguishable" {
  let header = error_text(InvalidHeaderField("K", 2147483648UL, 1UL, 1048576UL))
  let empty = error_text(EmptySource)
  assert_true(header.contains("K"))
  assert_true(header.contains("2147483648"))
  assert_true(!header.contains("empty source"))
  assert_true(empty.contains("empty source"))
  assert_true(!empty.contains("header"))
}
