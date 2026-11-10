///|
/// `DecodeStats.inconsistent` 的**结构性不可达**（LT-I，2026-11-10 对抗审计）。
///
/// ## 结论
///
/// `peel` 里 `resolved[s] is Some && rem[r].length() == 1` 那个分支对**任何**
/// 输入都不进入，因此 `inconsistent` 恒为 0，CLI 那句"非 0 时警告"永远不会
/// 触发。
///
/// ## 证明
///
/// 记 `rem[r]` = 收到符号 r 里「尚未解出」的源下标集合。
///
/// 1. 进入该分支时 `rem[r].length() == 1` 且 `s = rem[r][0]`，即 s 是 r
///    唯一剩下的未知下标。
/// 2. **不变式**：`resolved[s] is Some` ⟹ `s ∉ rem[*]`（任何 rem 都不含 s）。
///    归纳：s 只在 `resolved[s] = Some(...)` 那一刻由 None 变 Some，而在
///    同一时刻代码遍历 `rev[s]`（全部包含 s 的收到符号）并把 s 从每一个
///    `rem[r2]` 中删除。此后 s 不再能被加入任何 rem（`subset_for` 的结果
///    是第一遍一次性建好的，循环里只做删除）。
/// 3. 由 1 与 2：`resolved[s] is Some` ⟹ `s ∉ rem[r]` ⟹ `rem[r][0] != s`，
///    与 1 矛盾。
/// 4. 出队时的 `if rem[r].length() != 1 { continue }` 排除了"出队后状态
///    变化导致重入"这一条现实路径，所以矛盾不是"竞态"造成的。
///
/// 因此该分支不可达，`inconsistent` 恒 0。
///
/// ## 为什么保留字段而不是删掉
///
/// `DecodeStats` 是 `pub` 的，删字段属破坏性变更（下游编译失败）。而
/// 保留一个恒 0 的观测项代价很小，且将来引入 inactivation / 高斯消元时
/// （那会让"已解出"与"仍在 rem 里"同时成立），这里就是**免费的断言**。
///
/// 决策已写入 `docs/implementation.md` §12.4。

///|
/// **这条测试是证明的可执行版本**：在整个测试套件用到的各种输入形态上
/// （完整解码、各种失败、篡改、零符号、K=1、K=2、随机种子网格），
/// `inconsistent` 必须恒为 0。
///
/// 它不能"证明"不可达（有限输入永远不能），但它能把"有人改坏了不变式"
/// 变成一条会红的测试 —— 那正是这个悬空项最需要的保护。
test "LT-I: inconsistent is 0 on every reachable input shape" {
  // 1) 正常完整解码
  let k = 20
  let block = block_of(k, 4, 0x1234UL)
  let enc_ = build_encoder(block, 7UL)
  let full = encode_n(enc_, k, 2.5, 0)
  let (r1, s1) = decode_with_stats(7UL, k, 4, full, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  assert_true(r1.is_complete())
  inspect(s1.inconsistent, content="0")

  // 2) 数据不足（剥皮卡住）
  let few = encode_n(enc_, k, 0.6, 0)
  let (r2, s2) = decode_with_stats(7UL, k, 4, few, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  assert_true(!r2.is_complete())
  inspect(s2.inconsistent, content="0")

  // 3) 篡改（§5b 那个用例的形态）：改了字节也不该让计数器动
  let tampered : Array[ReceivedSymbol] = []
  for i, sym in full {
    if i == 0 {
      let arr = sym.data.to_array()
      arr[0] = (arr[0].to_int() ^ 0xFF).to_byte()
      tampered.push(ReceivedSymbol::{
        index: sym.index,
        data: Bytes::from_array(arr),
      })
    } else {
      tampered.push(sym)
    }
  }
  let (_r3, s3) = decode_with_stats(7UL, k, 4, tampered, 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  inspect(s3.inconsistent, content="0")

  // 4) 零符号
  let (_r4, s4) = decode_with_stats(7UL, k, 4, [], 0.1, 0.5) catch {
    _ => abort("decode raised")
  }
  inspect(s4.inconsistent, content="0")

  // 5) K=1 / K=2 边界（度分布与消去的最退化形态）
  for kk in [1, 2, 3] {
    let b = block_of(kk, 2, 0xA0UL + kk.to_uint64())
    let e = build_encoder(b, 11UL)
    let recv = encode_n(e, kk, 3.0, 0)
    let (_r, s) = decode_with_stats(11UL, kk, 2, recv, 0.1, 0.5) catch {
      _ => abort("decode raised for K=\{kk}")
    }
    inspect(s.inconsistent, content="0")
  }

  // 6) 种子网格：20 条种子 × 两种 overhead
  for t = 0; t < 20; t = t + 1 {
    let sd = 100UL + t.to_uint64()
    let b = block_of(10, 3, sd)
    let e = build_encoder(b, sd)
    for oh in [1.0, 2.0] {
      let recv = encode_n(e, 10, oh, 0)
      let (_r, s) = decode_with_stats(sd, 10, 3, recv, 0.1, 0.5) catch {
        _ => abort("decode raised at seed \{sd}")
      }
      if s.inconsistent != 0 {
        abort("inconsistent != 0 at seed \{sd} overhead \{oh}")
      }
    }
  }
}

///|
/// 反向保护：**如果**有人真的让那个分支可达（例如引入 inactivation 后
/// 不小心留下"已解出但仍在 rem 里"的状态），这条测试的注释就是他被引到
/// 的正确地方。这里只断言字段本身仍可读、类型仍是 Int32 —— 保证将来
/// "让它可达"这件事是**有意**的改动，而不是被静默删掉。
test "LT-I: the field is retained for API stability" {
  let stats : DecodeStats = {
    received: 0,
    subset_slots: 0,
    resolved: 0,
    xor_bytes: 0,
    inconsistent: 0,
  }
  inspect(stats.inconsistent, content="0")
  // 构造出来能带上非 0 值（字段是普通 Int32，不是常量）
  let marked : DecodeStats = { ..stats, inconsistent: 3, }
  inspect(marked.inconsistent, content="3")
}
