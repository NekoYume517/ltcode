///|
/// LT11 / LT12（2026-11-17 审计）：参数越出量化网格时的**报错对象**与
/// `Encoder::try_new`。
///
/// LT11（报错对象）：容器头把 `c` / `delta` 存成 `round(x*100)` 的单字节，
/// 所以可表示域是一张网格。修复前 `Encoder::new(c=0.004)` 把归一后的 `0.0`
/// 交给 `robust_soliton_checked`，用户收到
/// `degree distribution is not normalized: sum=0 (tolerance 1e-12)` ——
/// 他写的是 **c**，报文却指着一张他从没写过的分布表（LT3 在**容器头**路径
/// 上修掉的同一类错位，库入口一直没镜像）。`delta=1000` 更糟：报成
/// `sum=2.55`，那个数字是分布表的求和，从这里倒推不出「delta 越界」。
///
/// LT12（钳位 vs 严格）：`Encoder::new` 对**有限大值**做钳位
/// （`c=1000` → `c_q=255` → `2.55`），这与同一段注释里「`inf` 必须拦，
/// 否则会被静默吸成 2.55」的理由自相矛盾 —— 有限值走同一条路却不拦。
/// 修法是**让两条路都成文**：`new` 保留钳位（既有测试锁定），并新增
/// `Encoder::try_new` 作为能报错的严格入口；CLI 走严格入口。
test "LT11: an out-of-grid c names the parameter, not the distribution" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x02'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let outcome = match Encoder::new(block, 7UL, 0.004, 0.5) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  assert_true(outcome.contains("parameter c=0.004"))
  assert_true(outcome.contains("[0.005, 2.555)"))
  assert_true(!outcome.contains("not normalized"))
  // `delta` 的越界同理：修复前报 "sum=2.55"（分布表的求和）
  let dout = match Encoder::new(block, 8UL, 0.1, 1000.0) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  assert_true(dout.contains("parameter delta=1000"))
  assert_true(!dout.contains("not normalized"))
  // 下界方向也要点名 delta（0.004 → delta_q=0）
  let dlo = match Encoder::new(block, 9UL, 0.1, 0.004) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  assert_true(dlo.contains("parameter delta=0.004"))
}

///|
/// 解码端对称：`decode_with_stats` 走同一个钳位函数，因此同样的参数也报
/// `ParamOutOfImage`（而不是 `DistributionNotNormalized`）。CLI 路径不受
/// 影响：`unpack_container` 已经把头部域校验过了。
test "LT11: the decode entry reports the same parameter error" {
  let received : Array[ReceivedSymbol] = []
  let outcome = try {
    let _ = decode_with_stats(1UL, 10, 4, received, 0.004, 0.5)
    "ok"
  } catch {
    LtError::ParamOutOfImage(name, _, _, _) => "oog:\{name}"
    LtError::DistributionNotNormalized(_) => "dnn"
    _ => "other"
  }
  inspect(outcome, content="oog:c")
}

///|
/// LT12：`try_new` 对**有限大值**报错（区间语义），`new` 保留钳位。
/// 这是本轮唯一一处「同参数、两个入口、两种结论」的地方，必须逐条锁住。
test "LT12: try_new rejects finite values outside the grid, new clamps them" {
  let block = match SourceBlock::from_bytes(Bytes::make(4, b'\x05'), 1) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  // c = 1000：new 钳到 2.55（c_q=255），try_new 报错
  let clamped = match Encoder::new(block, 1UL, 1000.0, 0.5) {
    Ok(e) => e
    Err(e) => abort("new(c=1000) should clamp, got: \{error_text(e)}")
  }
  inspect(clamped.dist.pdf(1) > 0.0, content="true")
  let strict = match Encoder::try_new(block, 1UL, 1000.0, 0.5) {
    Ok(_) => "ok"
    Err(e) => error_text(e)
  }
  assert_true(strict.contains("parameter c=1000"))
  // 2.555 量化成 256（超出单字节）→ 严格版拒；2.55 是网格点 → 放行
  assert_true(
    match Encoder::try_new(block, 2UL, 2.555, 0.5) {
      Ok(_) => false
      Err(_) => true
    },
  )
  match Encoder::try_new(block, 3UL, 2.55, 0.5) {
    Ok(_) => ()
    Err(e) => abort("try_new(c=2.55) rejected: \{error_text(e)}")
  }
  // 下界：0.005 恰好落在中点（0.005*100 == 0.5），half-away-from-zero 进位
  // 到 1 → 严格版放行；0.0049 量化成 0 → 拒
  match Encoder::try_new(block, 4UL, 0.005, 0.5) {
    Ok(_) => ()
    Err(e) => abort("try_new(c=0.005) rejected: \{error_text(e)}")
  }
  assert_true(
    match Encoder::try_new(block, 5UL, 0.0049, 0.5) {
      Ok(_) => false
      Err(_) => true
    },
  )
  // delta 的严格上界：`delta*100` 必须进位到 <= 100。
  // 注意 `1.005*100` 在 binary64 里是 `100.49999999999999`（**低于**中点），
  // 所以 1.005 恰好落在域**内**（delta_q=100）；再高一点就越界 —— 这正是
  // LT13 那条「量化判据是 binary64 乘积，不是十进制的中点」的实例。
  match Encoder::try_new(block, 6UL, 0.1, 1.0) {
    Ok(_) => ()
    Err(e) => abort("try_new(delta=1.0) rejected: \{error_text(e)}")
  }
  match Encoder::try_new(block, 7UL, 0.1, 1.005) {
    Ok(_) => ()
    Err(e) => abort("try_new(delta=1.005) rejected: \{error_text(e)}")
  }
  assert_true(
    match Encoder::try_new(block, 8UL, 0.1, 1.0051) {
      Ok(_) => false
      Err(_) => true
    },
  )
}

///|
/// `try_new` 与 `new` 对**网格点**逐位相同：同一个 (seed, K, 参数) 造出的
/// 编码器必须给出逐字节相同的符号 —— 否则「用 try_new 造的容器能被
/// decode（钳位路径）解开」这条契约就是假的。
test "LT12: try_new and new agree bit for bit on grid parameters" {
  let k = 50
  let block = match SourceBlock::from_bytes(Bytes::make(k * 3, b'\x07'), k) {
    Ok(b) => b
    Err(e) => abort("from_bytes: \{error_text(e)}")
  }
  let a = match Encoder::new(block, 99UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("new: \{error_text(e)}")
  }
  let b = match Encoder::try_new(block, 99UL, 0.1, 0.5) {
    Ok(e) => e
    Err(e) => abort("try_new: \{error_text(e)}")
  }
  for i = 0; i < 20; i = i + 1 {
    let sa = a.symbol(i)
    let sb = b.symbol(i)
    if sa.index != sb.index || sa.data != sb.data {
      abort("symbols differ at index \{i}")
    }
  }
  // 非网格参数：new 与 try_new 归一后都等于 0.01，符号仍然相同
  let c = match Encoder::new(block, 99UL, 0.014, 0.5) {
    Ok(e) => e
    Err(e) => abort("new(0.014): \{error_text(e)}")
  }
  let d = match Encoder::try_new(block, 99UL, 0.014, 0.5) {
    Ok(e) => e
    Err(e) => abort("try_new(0.014): \{error_text(e)}")
  }
  for i = 0; i < 5; i = i + 1 {
    if c.symbol(i).data != d.symbol(i).data {
      abort("non-grid symbols differ at index \{i}")
    }
  }
}
