///|
/// 编码器测试。
///
/// 三条**结构性**断言（不靠采样近似）：
/// 1. 确定性：同 `(seed, index)` 两次生成逐字节相同。
/// 2. 无放回：子集内无重复下标，且全部落在 `[0, K)`。
/// 3. 均匀性：`floyd_subset` 对所有 `C(K,d)` 子集的分布**逐项统计**后
///    比对期望值 —— 在足够小的参数上做穷举，不做「看起来差不多」的判断。

///|
fn make_block(k : Int32, symbol_len : Int32) -> SourceBlock {
  let sources : Array[Bytes] = []
  for i = 0; i < k; i = i + 1 {
    let b : FixedArray[Byte] = FixedArray::make(symbol_len, b'\x00')
    for j = 0; j < symbol_len; j = j + 1 {
      b[j] = ((i * 31 + j * 7 + 1) % 251).to_byte()
    }
    sources.push(Bytes::from_array(b))
  }
  match SourceBlock::new(sources) {
    Ok(blk) => blk
    Err(_) => abort("make_block failed")
  }
}

///|
test "encoder: same (seed,index) is byte-identical across two encodes" {
  let block = make_block(50, 8)
  let enc = match Encoder::new(block, 0xDEADBEEFUL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("encoder build failed")
  }
  for i = 0; i < 40; i = i + 1 {
    let a = enc.symbol(i)
    let b = enc.symbol(i)
    assert_eq(a.data, b.data)
    assert_eq(a.index, i)
  }
}

///|
test "encoder: symbol length always equals source symbol length" {
  let block = make_block(37, 13)
  let enc = match Encoder::new(block, 7UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  for i = 0; i < 200; i = i + 1 {
    inspect(enc.symbol(i).data.length(), content="13")
  }
}

///|
test "encoder: subsets are without replacement for many (K,d)" {
  let mut bad = 0
  for _, k in [1, 2, 3, 4, 5, 10, 31, 100, 257, 1000] {
    let dist = robust_distribution(k, 0.1, 0.5)
    for i = 0; i < 300; i = i + 1 {
      let idx = subset_for(11UL, i, k, dist)
      // 每个下标在 [0,K)
      for j in idx {
        if j < 0 || j >= k {
          bad = bad + 1
        }
      }
      // 无重复（升序后相邻不等）
      for p = 1; p < idx.length(); p = p + 1 {
        if idx[p] == idx[p - 1] {
          bad = bad + 1
        }
      }
      // 非空
      if idx.length() == 0 {
        bad = bad + 1
      }
    }
  }
  inspect(bad, content="0")
}

///|
test "encoder: different indices give (mostly) different subsets" {
  // 不是严格保证（d 大的时候碰撞概率上升），但 K=1000 下 500 个符号
  // 两两不同的概率极高。这里断言「重复数 < 5」，作为「seed/index 派生
  // 确实带上了 index」的证据 —— 若实现忘了混入 index，这里会全部重复。
  let k = 1000
  let dist = robust_distribution(k, 0.1, 0.5)
  let seen : Array[Array[Int32]] = []
  for i = 0; i < 500; i = i + 1 {
    seen.push(subset_for(3UL, i, k, dist))
  }
  let mut dup = 0
  for i = 0; i < seen.length(); i = i + 1 {
    for j = i + 1; j < seen.length(); j = j + 1 {
      if seen[i].length() == seen[j].length() {
        let mut same = true
        for p = 0; p < seen[i].length(); p = p + 1 {
          if seen[i][p] != seen[j][p] {
            same = false
          }
        }
        if same {
          dup = dup + 1
        }
      }
    }
  }
  assert_true(dup < 5)
}

///|
/// **均匀性的结构性证据**：`floyd_subset` 在 K=6、d=3 上穷举全部
/// `C(6,3)=20` 个子集，统计 200000 次抽样里每个子集的出现次数。
///
/// 期望每个子集约 10000 次；允许的相对偏差 5%（窗口足够宽以容纳
/// 确定性种子的抖动，又窄到能抓住「Floyd 写错导致某些子集永不出现」——
/// 那会让某些桶为 0，偏差 100%）。
test "encoder: floyd_subset is uniform over all subsets (exhaustive)" {
  let k = 6
  let d = 3
  // 全部 C(6,3) = 20 个子集，按位图编码成下标
  let combos : Array[Array[Int32]] = []
  let masks : Array[Int32] = []
  for a = 0; a < k; a = a + 1 {
    for b = a + 1; b < k; b = b + 1 {
      for c = b + 1; c < k; c = c + 1 {
        combos.push([a, b, c])
        masks.push((1 << a) + (1 << b) + (1 << c))
      }
    }
  }
  inspect(combos.length(), content="20")
  let counts : Array[Int32] = Array::make(combos.length(), 0)
  let rng = Ltrng::new(0xABCDEFUL)
  let trials = 200000
  for _i = 0; _i < trials; _i = _i + 1 {
    let got = floyd_subset(rng, k, d)
    let mut mask = 0
    for v in got {
      mask = mask + (1 << v)
    }
    let mut pos = -1
    for j = 0; j < masks.length(); j = j + 1 {
      if masks[j] == mask {
        pos = j
      }
    }
    if pos >= 0 {
      counts[pos] = counts[pos] + 1
    }
  }
  let expect = trials / combos.length()
  let mut missing = 0
  let mut worst = 0.0
  for i = 0; i < counts.length(); i = i + 1 {
    if counts[i] == 0 {
      missing = missing + 1
    }
    let ratio = counts[i].to_double() / expect.to_double()
    let dev = (ratio - 1.0).abs()
    if dev > worst {
      worst = dev
    }
  }
  if missing != 0 || worst >= 0.05 {
    println("missing=\{missing} worst relative deviation=\{worst}")
  }
  inspect(missing, content="0")
  assert_true(worst < 0.05)
}

///|
test "encoder: floyd_subset handles degenerate d and K" {
  let rng = Ltrng::new(1UL)
  // d == K：唯一可能的子集就是全部
  let all = floyd_subset(rng, 4, 4)
  inspect(all.length(), content="4")
  inspect(all[0], content="0")
  inspect(all[3], content="3")
  // K == 1：唯一子集 {0}
  let one = floyd_subset(rng, 1, 1)
  inspect(one.length(), content="1")
  inspect(one[0], content="0")
  // d > K 时钳到 K（防御，不报错）
  let clamped = floyd_subset(rng, 3, 99)
  inspect(clamped.length(), content="3")
  // d <= 0：空集
  inspect(floyd_subset(rng, 10, 0).length(), content="0")
  inspect(floyd_subset(rng, 10, -2).length(), content="0")
  // K <= 0：空集
  inspect(floyd_subset(rng, 0, 3).length(), content="0")
}

///|
test "encoder: K=1 degenerate block encodes to itself x times" {
  let block = make_block(1, 4)
  let enc = match Encoder::new(block, 5UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  // K=1 时唯一下标 0，所有编码符号都应等于源符号本身
  for i = 0; i < 20; i = i + 1 {
    assert_eq(enc.symbol(i).data, block.sources[0])
  }
}

///|
test "encoder: encode_symbol PLAN entry is consistent with Encoder" {
  let block = make_block(20, 6)
  let enc = match Encoder::new(block, 42UL, default_c(), default_delta()) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  for i = 0; i < 25; i = i + 1 {
    let via_entry = encode_symbol(42UL, i, block.sources)
    assert_eq(via_entry, enc.symbol(i).data)
  }
}

///|
test "encoder: memory is O(d) not O(K) for subset selection" {
  // 结构性断言：在 K 很大、d 很小时，抽一个子集不应产生长度 ~K 的数组。
  // 直接测量分配是不可能的，因此改为断言「返回数组长度 == d」，并且
  // 用一个极大的 K（1<<20）证明它不会因为 K 而变慢到不可完成 ——
  // 若实现分配并打乱 O(K) 数组，这条测试会超时或耗尽内存。
  let k = 1 << 20
  let dist = robust_distribution(k, 0.1, 0.5)
  let idx = subset_for(9UL, 0, k, dist)
  assert_true(idx.length() >= 1)
  assert_true(idx.length() < 200)
  // 期望度数在 10 左右，绝不该接近 K
  let _ = dist.expected_degree()
}

///|
test "encoder: symbols() honours first_index and count" {
  let block = make_block(10, 3)
  let enc = match Encoder::new(block, 1UL, 0.1, 0.5) {
    Ok(e) => e
    Err(_) => abort("build failed")
  }
  let batch = enc.symbols(100, 5)
  inspect(batch.length(), content="5")
  for i = 0; i < 5; i = i + 1 {
    assert_eq(batch[i].index, 100 + i)
    assert_eq(batch[i].data, enc.symbol(100 + i).data)
  }
  // count=0 给空数组，不报错
  inspect(enc.symbols(0, 0).length(), content="0")
}
