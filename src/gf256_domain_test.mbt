///|
/// GF(256) 公开 API 的输入域与指数回绕（LT-E，2026-11-10 对抗审计）。
///
/// ## 缺陷形态（修复前）
///
/// 三个公开函数都没有输入域约束，而表查找是**下标访问**，因此越界输入
/// 要么静默给错值、要么 trap：
///
/// ```
/// gf256_pow(0xFF, 2000000000)   → 244   （正确 27）
/// gf256_pow(3, -1)              → trap  （负指数落进 exp[负数]）
/// gf256_mul(256, 1)             → trap  （log[256] 越界）
/// gf256_mul_peasant(256, 1)     → 0     （这个有 `& 0xFF`，因此两者不一致）
/// ```
///
/// 根因在 `gf256_pow` 的 `exp[la * n % 255]`：`la * n` 是 Int32 乘法，
/// `7 * 2000000000` 溢出成负数，`% 255` 之后落在一个**不对应任何真实代数
/// 结论**的下标上 —— 静默错值，比 trap 更危险（没有崩溃、没有报警，算出
/// 来的就是错的）。
///
/// ## 参考值来源（两套独立算法，都算得 27）
///
/// 1. **逐次相乘**：`r = 1; for _ in range(n % 255): r = mul(r, a)`，
///    `mul` 用位运算（shift + XOR 0x11B）实现，完全不用 log/exp 表。
/// 2. **对数表**：由生成元 3 的连续幂构造 exp/log（与本项目
///    `gf256_build_tables` 同构），再算 `exp[(log[a] * (n % 255)) % 255]`。
///
/// 两条路都不共享 `gf256_pow` 的代码路径，因此它们一致才说明修复正确。
///
/// ## 修法与 peasant 对齐
///
/// `gf256_mul_peasant` 一直有 `a & 0xFF` / `b & 0xFF`，它的结果对越界输入
/// 是"按低 8 位解释"（`mul(256, 1) == 0`）。表实现向它看齐：mul / inv / pow
/// 入口统一 `& 0xFF`。这既消除了 trap，又让两个实现的行为在**全部**
/// Int32 输入上一致 —— 而不只是 `[0, 255]` 上一致。

///|
/// **pow 的指数不能再回绕**：`0xFF ^ 2000000000`。
///
/// 修复前 244（`la * n` 溢出后 `% 255` 落到错误下标）；正确 27
/// （`2000000000 % 255 = 65`，`log[0xFF] = 7`，`7 × 65 % 255 = 200`，
/// `exp[200] = 27`）。
test "LT-E: pow does not wrap a huge exponent (0xFF^2000000000 == 27)" {
  inspect(gf256_pow(0xFF, 2000000000), content="27")
  // 与"反复相乘"这条独立路径一致（指数先归一到 [0, 255)）
  let mut acc = 1
  for _i = 0; _i < 2000000000 % 255; _i = _i + 1 {
    acc = gf256_mul_peasant(acc, 0xFF)
  }
  inspect(acc, content="27")
}

///|
/// 更多大指数：任何一个都不能凭空给出错值。
///
/// 这里逐个用 peasant（无表）路径复算，因此不依赖 exp/log 表的正确性。
test "LT-E: every large exponent agrees with repeated peasant multiplication" {
  let bases = [3, 0x1D, 0x57, 0xFF, 0x80]
  let exponents = [255, 256, 510, 1000000, 2147483647]
  for a in bases {
    for n in exponents {
      // 参考：a^(n mod 255)，用无表乘法逐次累乘
      let e = n % 255
      let mut acc = 1
      for _i = 0; _i < e; _i = _i + 1 {
        acc = gf256_mul_peasant(acc, a)
      }
      inspect(gf256_pow(a, n), content="\{acc}")
    }
  }
}

///|
/// **负指数**：代数上 `a^-1` 就是 `inv(a)`，而 `a^-k` 是 `inv(a)^k`。
///
/// 修复前 `gf256_pow(3, -1)` 直接 trap（`exp[负数]`）。修复后按
/// `((n % 255) + 255) % 255` 归一（-1 → 254），与 `inv` 一致。
test "LT-E: negative exponents are the inverse, not a trap" {
  inspect(gf256_pow(3, -1), content="246")
  // 与 inv 交叉核对
  let inv3 = match gf256_inv(3) {
    Some(v) => v
    None => abort("inv(3) must exist")
  }
  inspect(gf256_pow(3, -1), content="\{inv3}")
  // 全部 255 个非零元：a^-1 == inv(a)
  let mut bad = 0
  for a = 1; a < 256; a = a + 1 {
    let got = gf256_pow(a, -1)
    let want = match gf256_inv(a) {
      Some(v) => v
      None => -1
    }
    if got != want {
      bad = bad + 1
    }
  }
  inspect(bad, content="0")
  // a^-k == (a^-1)^k
  for k in [1, 2, 5, 100, 255] {
    let lhs = gf256_pow(7, -k)
    let rhs = gf256_pow(gf256_pow(7, -1), k)
    inspect(lhs, content="\{rhs}")
  }
}

///|
/// **mul 的越界输入不再 trap，且与 peasant 完全一致**。
///
/// `gf256_mul_peasant` 一直有 `& 0xFF`，因此 `mul_peasant(256, 1) == 0`。
/// 修复前表实现的 `mul(256, 1)` 直接 trap —— 同一个包里的两个乘法在
/// 同一个输入上给出"崩溃"和"0"两种结果，这是最坏的不一致：peasant 是
/// 文档指定的**审计锚点**，两者必须能互相复算。
test "LT-E: mul masks its inputs like peasant does (no trap on 256)" {
  inspect(gf256_mul(256, 1), content="0")
  inspect(gf256_mul_peasant(256, 1), content="0")
  inspect(gf256_mul(1, 256), content="0")
  // 负数（Int32 意义上的）同样按低 8 位解释
  inspect(gf256_mul(-1, 1), content="\{gf256_mul_peasant(-1, 1)}")
  inspect(gf256_mul(0x1FF, 0x100), content="\{gf256_mul_peasant(0x1FF, 0x100)}")
}

///|
/// **两个乘法实现在全部越界输入上也一致**：这是"对齐"这句话的真凭据，
/// 不是抽样。
///
/// 取一组覆盖 0..255、256 的幂、负数、Int32 端点的输入，逐对比较。
test "LT-E: tabled mul agrees with peasant over out-of-domain inputs" {
  let values = [
    0, 1, 2, 127, 128, 255, 256, 257, 511, 512, 1024, -1, -2, -255, -256, 65535,
    65536, 2147483647, -2147483648,
  ]
  let mut bad = 0
  let mut first = ""
  for a in values {
    for b in values {
      let t = gf256_mul(a, b)
      let p = gf256_mul_peasant(a, b)
      if t != p {
        if bad == 0 {
          first = "(\{a}, \{b}): table=\{t} peasant=\{p}"
        }
        bad = bad + 1
      }
    }
  }
  if bad != 0 {
    println(first)
  }
  inspect(bad, content="0")
}

///|
/// **inv 的越界输入**：`gf256_inv(256)` 修复前 trap（`log[256]`）。
/// 修复后与 `inv(0)`（`256 & 0xFF == 0`）同一个答案：`None`。
test "LT-E: inv masks its input instead of trapping on 256" {
  inspect(gf256_inv(256) is None, content="true")
  // 257 & 0xFF == 1 → inv(1) == 1
  inspect(gf256_inv(257), content="Some(1)")
  inspect(gf256_inv(-1), content="\{gf256_inv(255)}")
}

///|
/// 域内输入的结果**一个字都不能变**：`& 0xFF` 对 `[0, 255]` 是恒等映射，
/// 因此这条测试锁定"修越界没有顺手改坏正常路径"。
test "LT-E: masking does not change any in-domain result" {
  // FIPS-197 锚点
  inspect(gf256_mul(0x57, 0x83), content="193")
  // 单位元 / 零元
  for x = 0; x < 256; x = x + 1 {
    inspect(gf256_mul(x, 1), content="\{x}")
    inspect(gf256_mul(0, x), content="0")
  }
  // pow 的域内指数
  let a = 0x1D
  let mut acc = 1
  for n = 0; n <= 8; n = n + 1 {
    inspect(gf256_pow(a, n), content="\{acc}")
    acc = gf256_mul(acc, a)
  }
  inspect(gf256_pow(a, 255), content="1")
  // inv 全 255 个
  let mut bad = 0
  for a = 1; a < 256; a = a + 1 {
    match gf256_inv(a) {
      Some(inv) => if gf256_mul(a, inv) != 1 { bad = bad + 1 }
      None => bad = bad + 1
    }
  }
  inspect(bad, content="0")
}

///|
/// `pow(a, 0) == 1` 对**任何** a 成立（含 0 与越界值），这是文档承诺的
/// 约定，不能被 `& 0xFF` 掩码顺手改掉。
test "LT-E: pow(a, 0) is 1 for every a including out-of-domain" {
  for a in [0, 1, 255, 256, -1, 2147483647] {
    inspect(gf256_pow(a, 0), content="1")
  }
}
