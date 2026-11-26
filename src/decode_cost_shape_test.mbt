///|
/// **LT44-d**：`subset_slots` 随 `K` 单调增长 —— 它是 CSR 建表成本的主项。
///
/// ## 实测（n=300, sl=4，只改 K）
///
/// ```text
///   K      subset_slots   xor_bytes   resolved
///   50        1592          6168         50
///   150       2192          8168        150
///   300       2700           836         23
///   600       3306           188         11
///   1200      4055            80          7
/// ```
///
/// 两列**形状完全不同**，这正是不该拿 `xor_bytes` 当"总工作量"的原因：
///
/// - `subset_slots` 随 K **单调增**：它是建 CSR 时登记的关联总数，而每个
///   符号的度数由 `robust_soliton` 在 K 上采样（K 大 -> 允许更大的度数），
///   所以它反映的是**建表**成本，跟能不能解出来无关。
/// - `xor_bytes` 在 K=150（`resolved=150`，剥皮真在推进）达到峰，之后
///   **塌下去**：K=300 时只解出 23 个源符号就队列空了，消去阶段的循环根本
///   没跑几次。它是"**实际做了多少 XOR**"，不是"理论上限"。
///
/// 所以墙钟在 `K ≈ n` 处的峰（9.93 s）由 `subset_slots`（CSR 遍历）主导，
/// 而不是 `xor_bytes`。这条锁住这个方向性事实：**K 增大时建表成本单调增**。
test "LT44: subset_slots grows monotonically with K at fixed n" {
  let n = 300
  let sl = 4
  let k1 = n / 6
  let k2 = n / 2
  let k3 = n
  let s1 = lt44_stats(k1, sl, n) catch {
    e => abort("K=\{k1} decode failed: \{error_text(e)}")
  }
  let s2 = lt44_stats(k2, sl, n) catch {
    e => abort("K=\{k2} decode failed: \{error_text(e)}")
  }
  let s3 = lt44_stats(k3, sl, n) catch {
    e => abort("K=\{k3} decode failed: \{error_text(e)}")
  }
  assert_true(s1.subset_slots < s2.subset_slots)
  assert_true(s2.subset_slots < s3.subset_slots)
}

///|
/// **LT44-e**：`xor_bytes` 只在剥皮真推进时才增长；推不动时它塌下去。
///
/// 这条与上一条合起来说明"两个计数器分别度量两件不同的事"，
/// 不能拿其中一个当"总耗时"的代理。具体判据：`resolved` 从 n/2 掉到很小
/// 时，`xor_bytes` 必须显著下降（而不是持平或上升）。
test "LT44: xor_bytes tracks actual peeling progress, so it collapses when peeling stalls" {
  let n = 300
  let sl = 4
  let s_progress = lt44_stats(n / 2, sl, n) catch {
    e => abort("K=n/2 decode failed: \{error_text(e)}")
  }
  let s_stalled = lt44_stats(n * 2, sl, n) catch {
    e => abort("K=2n decode failed: \{error_text(e)}")
  }
  // 前提：前者真解出了东西，后者几乎没解出
  assert_true(s_progress.resolved > s_stalled.resolved)
  // 结论：实际 XOR 量必须跟着降
  assert_true(s_progress.xor_bytes > s_stalled.xor_bytes)
  // 而建表成本（subset_slots）反而更高 —— 两列方向相反，正是本条要说明的
  assert_true(s_stalled.subset_slots > s_progress.subset_slots)
}

///|
/// **LT44-f**：计数器只由输入决定，跨调用不变。
///
/// 这是"零噪声判据"的前提：若计数器本身带随机性，前面所有比值判据
/// 都站不住。同一输入解两次，四个计数器必须逐值相等。
test "LT44: work counters are deterministic across repeated decodes" {
  let a = lt44_stats(200, 4, 400) catch {
    e => abort("first decode failed: \{error_text(e)}")
  }
  let b = lt44_stats(200, 4, 400) catch {
    e => abort("second decode failed: \{error_text(e)}")
  }
  assert_eq(a.subset_slots, b.subset_slots)
  assert_eq(a.xor_bytes, b.xor_bytes)
  assert_eq(a.received, b.received)
  assert_eq(a.resolved, b.resolved)
}
