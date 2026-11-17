///|
/// LT24（2026-11-17-b 审计）：`pack_container` 是**第三条**写参数的入口，
/// 它漏掉了「非有限参数必须显式拒绝」这一条判断。
///
/// 判断只有一份，写在 `src/container.mbt` 的 `non_finite_param` 里，由四个
/// 入口共用：`Encoder::new`、`Encoder::try_new`、`decode_with_stats`
/// （经 `quantized_pair` / `quantized_pair_strict`）与 `pack_container`。
/// 修复前 `pack_container` 没过它，于是：
///
/// - `c = inf` → `quantize_param(inf)` 经 `.to_int()` 饱和再钳到 255 →
///   **写出的头被 `unpack_container` 接受**（`c_q = 255` 在域内），
///   `decode` 于是用 `c = 2.55` 去解 —— 用户要的是 `inf`，拿到的是 2.55，
///   全链路一声不吭。这正是 `src/container.mbt` 自己那段注释写的
///   「若不拦，`c=inf` 会被静默吸成 2.55（一个合法的分布参数）」，
///   也是 LT12 在 `Encoder::new` 上修掉的同一件事在第三条入口的复发；
/// - `c = nan` → `c_q = 0`、`delta = inf` → `delta_q = 255`：写出**读不回**
///   的头（`unpack_container` 判 `c_q`/`delta_q` 越界）—— LT20/LT23 同族。
///
/// API.md §8 那句「越出像内域的参数（c<0.005、delta<0.005、delta>1）写出的头
/// 会被 unpack 明确拒绝（`InvalidHeaderField`，不是静默坏数据）」对 `c=inf`
/// 是**不成立**的：`inf` 量化后落在**像内**，unpack 没有任何理由拒绝它。
/// 只有编码侧在写之前拦，才能让这句话变成真的。
test "LT24: pack_container rejects non-finite c" {
  let data = Bytes::from_array([b'\x31', b'\x32', b'\x33', b'\x34'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let inf = 1.0 / 0.0
  // 第三条入口现在必须和第一条说同一句话（同一份判断、同一个变体）。
  let from_encoder = match Encoder::new(block, 9UL, inf, 0.5) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  let outcome = try {
    let packed = pack_container(block, 9UL, data, inf, 0.5, [])
    let accepted = try {
      let c = unpack_container(packed)
      "unpack-accepted c=\{c.c}"
    } catch {
      e => "unpack-raise: \{error_text(e)}"
    }
    "packed c_q=\{packed[5].to_int()} → \{accepted}"
  } catch {
    e => "pack-raise: \{error_text(e)}"
  }
  // `Encoder::new` 的文本是拒绝理由的**唯一**出处：pack 必须与之逐字相同。
  assert_true(!from_encoder.contains("ok"))
  assert_eq(outcome, "pack-raise: " + from_encoder)
}

///|
/// `nan` 与非有限的 `delta` 同样要在写之前拒（修复前 `nan` 写出 `c_q=0`、
/// `delta=inf` 写出 `delta_q=255`，两者都是「写得出、读不回」）。
test "LT24: pack_container rejects non-finite delta and nan" {
  let data = Bytes::from_array([b'\x41', b'\x42', b'\x43', b'\x44'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let inf = 1.0 / 0.0
  let nan = 0.0 / 0.0
  let probe = fn(c : Double, d : Double) -> String {
    try {
      let packed = pack_container(block, 9UL, data, c, d, [])
      let back = try {
        let cu = unpack_container(packed)
        "unpack-accepted c=\{cu.c} delta=\{cu.delta}"
      } catch {
        e => "unpack-raise: \{error_text(e)}"
      }
      "packed c_q=\{packed[5].to_int()} delta_q=\{packed[6].to_int()} → \{back}"
    } catch {
      e => "pack-raise: \{error_text(e)}"
    }
  }
  let nan_c = probe(nan, 0.5)
  let inf_d = probe(0.1, inf)
  let nan_d = probe(0.1, nan)
  // 三者的文本都必须点名**用户实际给的那个参数值**（不是一张分布表）。
  // `Double` 的渲染由 `error_text` 决定：`inf` → `Infinity`、`nan` → `NaN`。
  assert_true(nan_c.contains("NaN"))
  assert_true(inf_d.contains("Infinity"))
  assert_true(nan_d.contains("NaN"))
  inspect(nan_c.contains("pack-raise"), content="true")
  inspect(inf_d.contains("pack-raise"), content="true")
  inspect(nan_d.contains("pack-raise"), content="true")
}

///|
/// 不误伤：`c = 1000`（有限、越像）在 `pack_container` 上仍是**钳位**
/// 语义 —— 写出 `c_q = 255`，且 `unpack` 接受它。这是 LT12 明确保留的既有
/// 契约（`Encoder::new` 钳位、`Encoder::try_new` 拒绝），第三条入口的
/// 非有限检查**不能**顺手把这条也收掉。
test "LT24: finite out-of-image c still packs as c_q=255" {
  let data = Bytes::from_array([b'\x51', b'\x52', b'\x53', b'\x54'])
  let block = match SourceBlock::from_bytes(data, 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let enc = match Encoder::new(block, 5UL, 1000.0, 0.5) {
    Ok(e) => e
    Err(e) => abort("clamping encoder rejected c=1000: \{error_text(e)}")
  }
  let packed = pack_container(block, 5UL, data, 1000.0, 0.5, enc.symbols(0, 4)) catch {
    e => abort("pack raised for finite c=1000: \{error_text(e)}")
  }
  assert_eq(packed[5].to_int(), 255)
  let c = unpack_container(packed) catch {
    e => abort("unpack raised for c_q=255: \{error_text(e)}")
  }
  assert_true((c.c - 2.55).abs() < 0.000000000001)
  assert_true(decode_verified(c).is_complete())
}
