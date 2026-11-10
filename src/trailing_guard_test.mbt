///|
/// 容器尾部多余字节（LT-D，2026-11-10 对抗审计）。
///
/// ## 缺陷形态（修复前）
///
/// `unpack_container` 读完 `count` 个符号就返回，**从不检查 `pos` 是否
/// 正好用完文件**。于是三种「这不是同一份文件」全都 exit 0 并打印
/// `decoded OK: ... (checksum verified)`：
///
/// ```
/// $ cat good.ltc; printf 'JUNKJUNKJUNK...' >> junk.ltc
/// $ ltcode decode --input junk.ltc --out o.bin
/// decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
/// exit 0
///
/// $ cat good.ltc good.ltc > double.ltc        # 两个完整容器首尾相接
/// $ ltcode decode --input double.ltc --out o.bin
/// decoded OK: K=100 symbols=300 payload=4000 bytes (checksum verified)
/// exit 0
///
/// $ # 只把 count 从 300 改成 2（前两个符号完好）
/// decoded OK: K=100 symbols=2 payload=4000 bytes (checksum verified)
/// exit 0
/// ```
///
/// 第三种最危险：`payload_hash` 抓不住它 —— 剩下的两个符号是**完好的**，
/// 而哈希是对解出来的 payload 算的。因此 README 里「能抓住拼接错误」
/// 那句话在修复前是**不成立的**，已同步改成如实描述。
///
/// ## 修法
///
/// 读完 `count` 个符号后要求 `pos == data.length()`，否则 raise
/// `TrailingBytes(已消费, 总长)`；CI 层 exit 3。这与 `TruncatedSymbol` 是
/// **两个方向**：截断是「读不到」，尾部多余是「读完了还剩」。混进同一个
/// 变体会让调用方分不清该重传还是该丢弃。

///|
/// 造一个 K=20、80 符号的完好容器。
fn trailing_base_container() -> Bytes {
  let block = sample_block(20, 4)
  let payload = sample_payload(block)
  let enc = match Encoder::new(block, 0xAAUL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 80)
  pack_container(block, 0xAAUL, payload, 0.1, 0.5, symbols)
}

///|
/// 让 `try` 的错误类型显式落到 `LtError`。
fn unpack_outcome_d(data : Bytes) -> String raise LtError {
  let c = unpack_container(data)
  "unpacked symbols=\{c.symbols.length()}"
}

///|
/// **核心回归 1**：容器后追加 12 个 `JUNK` 字节。
///
/// 修复前：`decoded OK ... checksum verified` / exit 0。
/// 修复后：`TrailingBytes(消费字节, 总字节)` / exit 3。
test "LT-D: appended junk bytes are rejected instead of silently ignored" {
  let good = trailing_base_container()
  let junk : Array[Byte] = []
  for i = 0; i < 12; i = i + 1 {
    junk.push(b'J')
    junk.push(b'U')
    junk.push(b'N')
    junk.push(b'K')
  }
  let arr = good.to_array()
  for b in junk {
    arr.push(b)
  }
  let padded = Bytes::from_array(arr)
  inspect(padded.length(), content="\{good.length() + 48}")
  let outcome = unpack_outcome_d(padded) catch {
    TrailingBytes(consumed, total) => {
      // 已消费 = 恰好一个完整容器的长度
      inspect(consumed, content="\{good.length()}")
      inspect(total, content="\{padded.length()}")
      "trailing"
    }
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="trailing")
}

///|
/// **核心回归 2**：两个完整容器首尾相接。
///
/// 这是「拼接」最自然的形态（`cat a.ltc b.ltc > c.ltc`），也是
/// `payload_hash` 单独抓不住的那一类：两份文件各自都合法。
test "LT-D: two concatenated containers are rejected" {
  let good = trailing_base_container()
  let arr = good.to_array()
  for b in good.to_array() {
    arr.push(b)
  }
  let double = Bytes::from_array(arr)
  inspect(double.length(), content="\{good.length() * 2}")
  let outcome = unpack_outcome_d(double) catch {
    TrailingBytes(consumed, total) => "\{consumed}/\{total}"
    e => "other: \{error_text(e)}"
  }
  inspect(outcome, content="\{good.length()}/\{double.length()}")
}

///|
/// **核心回归 3**：`count` 被改小（300 → 2），后面 298 个符号变成"尾部多余"。
///
/// 这个用例是 `payload_hash` **明确抓不住**的：前两个符号完好，若它们恰好
/// 足以解出全部源符号，哈希会通过。修复前它确实 exit 0；修复后
/// `count` 与文件长度不自洽，unpack 直接拒绝。
test "LT-D: a shrunken count is rejected as trailing bytes" {
  let block = sample_block(100, 4)
  let payload = sample_payload(block)
  let enc = match Encoder::new(block, 7UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let symbols = enc.symbols(0, 300)
  let packed = pack_container(block, 7UL, payload, 0.1, 0.5, symbols)
  // 先确认原容器完整可用
  let ok = unpack_container(packed) catch { _ => abort("good failed") }
  inspect(ok.symbols.length(), content="300")
  // 把 count 改成 2
  let arr = packed.to_array()
  arr[39] = b'\x00'
  arr[40] = b'\x00'
  arr[41] = b'\x00'
  arr[42] = b'\x02'
  let outcome = unpack_outcome_d(Bytes::from_array(arr)) catch {
    TrailingBytes(consumed, _) => "trailing at \{consumed}"
    e => "other: \{error_text(e)}"
  }
  // 43 + 2*(4+4) = 59
  inspect(outcome, content="trailing at 59")
}

///|
/// 校验不能误伤：**恰好**用完文件的容器必须继续通过（这是所有正常文件）。
test "LT-D: a container that ends exactly at its last symbol still unpacks" {
  let good = trailing_base_container()
  let c = unpack_container(good) catch {
    _ => abort("exact container rejected")
  }
  inspect(c.symbols.length(), content="80")
  inspect(c.k, content="20")
  // 零符号容器：43 字节头，读完就是末尾 —— 也必须通过
  let block = sample_block(4, 2)
  let payload = sample_payload(block)
  let zero = pack_container(block, 1UL, payload, 0.1, 0.5, [])
  inspect(zero.length(), content="43")
  let zc = unpack_container(zero) catch {
    _ => abort("zero container rejected")
  }
  inspect(zc.symbols.length(), content="0")
}

///|
/// 变体文案：必须能当场分辨「尾部多余」与「被截断」—— 两者对调用方的
/// 动作指引相反（一个该丢弃文件，一个该重传）。
test "LT-D: error_text distinguishes trailing bytes from truncation" {
  let trailing = error_text(TrailingBytes(13243UL, 13291UL))
  let truncated = error_text(TruncatedSymbol(3, 43))
  assert_true(trailing.contains("trailing"))
  assert_true(trailing.contains("13243"))
  assert_true(trailing.contains("13291"))
  assert_true(truncated.contains("truncated"))
  // 两条措辞不能互相污染
  assert_true(!trailing.contains("truncated"))
  assert_true(!truncated.contains("trailing"))
  // 也不能借用"checksum"（那是内容坏了，不是结构坏了）
  assert_true(!trailing.contains("checksum"))
}
