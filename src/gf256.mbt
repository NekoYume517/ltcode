///|
/// GF(256) 域运算，约化多项式 `x^8 + x^4 + x^3 + x + 1`（`0x11B`，AES 用的那个）。
///
/// **乘法用对数/反对数表**，但表本身是**由生成元 3 的连续幂构造出来的**，不是
/// 硬编码的 256 项数组。理由：手抄 256 项极可能错一两个数字，而一个错项会让
/// 乘法在极少数输入上静默出错 —— 这种 bug 在测试里可能躲很久，因为大部分
/// 输入对仍然对。用生成元构造则只有「3 到底是不是本原元」这一个假设，
/// 而那一点由 `gf256_test.mbt` 的 65536 对全量比对锁定。
///
/// 生成元 3 = x + 1 在 0x11B 下是本原元：它的幂遍历全部 255 个非零元素。
/// 这个事实本身也由全量比对间接验证 —— 如果 3 不是本原元，log 表会有空洞，
/// 乘法结果会与无表实现不一致。

///|
/// 约化多项式低 8 位的等价形式：`x^8 = x^4 + x^3 + x + 1` → `0x1B`。
/// 写在这里是为了让「0x11B」与「0x1B」的换算有唯一出处，而不是散落在代码里。
let gf256_reduction_low : Int32 = 0x1B

///|
/// 表容器。`exp` 长度 512：后 256 项是前 256 项的复制，因此 `exp[a+b]`
/// 对 `0 <= a+b < 512` 永远不用做 `% 255`。`log[0]` 未定义（填 -1 哨兵）。
priv struct GfTables {
  exp : FixedArray[Int32]
  log : FixedArray[Int32]
}

///|
/// 由生成元 3 的连续幂构造 exp/log 表。
fn gf256_build_tables() -> GfTables {
  let exp : FixedArray[Int32] = FixedArray::make(512, 0)
  let log : FixedArray[Int32] = FixedArray::make(256, -1)
  let mut x = 1
  for i = 0; i < 255; i = i + 1 {
    exp[i] = x
    log[x] = i
    // x <- x * 3，而 3 = 1 + x，所以 x*3 = x ^ (x*2)，后者是带约化的左移。
    let doubled = gf256_double(x)
    x = x ^ doubled
  }
  // 复制前 255 项到 [255, 510)，使 exp 下标无需取模。
  for i = 0; i < 255; i = i + 1 {
    exp[i + 255] = exp[i]
  }
  { exp, log, }
}

///|
/// `x * 2` 在 GF(256)：左移一位，若溢出则异或约化多项式的低 8 位。
/// 这是 xtime()，是 FIPS-197 里定义的 AES 基本操作。
fn gf256_double(x : Int32) -> Int32 {
  let shifted = x << 1
  if (shifted & 0x100) != 0 {
    (shifted ^ gf256_reduction_low) & 0xFF
  } else {
    shifted
  }
}

///|
/// 进程内唯一份表，模块初始化时构造一次。
let gf256_tables : GfTables = gf256_build_tables()

///|
/// 加法 = XOR。
pub fn gf256_add(a : Int32, b : Int32) -> Int32 {
  a ^ b
}

///|
/// 乘法。任一方为 0 时结果是 0（log[0] 无定义，必须先拦掉）。
pub fn gf256_mul(a : Int32, b : Int32) -> Int32 {
  if a == 0 || b == 0 {
    0
  } else {
    let la = gf256_tables.log[a]
    let lb = gf256_tables.log[b]
    // la, lb ∈ [0, 255)，和 ∈ [0, 509)，落在 exp 的 512 项内。
    gf256_tables.exp[la + lb]
  }
}

///|
/// 乘法逆元。0 没有逆元，返回 `None` 而不是 0 —— 返回 0 会让
/// `mul(0, inv(0)) == 0` 这种错误静默传播。
pub fn gf256_inv(a : Int32) -> Int32? {
  if a == 0 {
    None
  } else {
    let la = gf256_tables.log[a]
    Some(gf256_tables.exp[255 - la])
  }
}

///|
/// 幂。`a^0 == 1`（包括 `0^0 == 1`，与常规代数约定一致，也与「编码符号的
/// 系数恒等式」无关 —— 本项目只用 `a^n` 于非零 a 的逆元推导）。
pub fn gf256_pow(a : Int32, n : Int32) -> Int32 {
  if n == 0 {
    1
  } else if a == 0 {
    0
  } else {
    let la = gf256_tables.log[a]
    gf256_tables.exp[la * n % 255]
  }
}

///|
/// **测试对照基准**：完全不用表的俄罗斯农民乘法。
///
/// 原理上它和表实现毫无共享：它逐位处理 `y` 的每一个二进制位，用「加倍 + 条件
/// 约化」累积。这正是 `gf256_mul` 必须与之一致的东西 —— 两张表是「3 的幂」的
/// 产物，这里是「位运算」的产物，两者相等才是真证据。
///
/// 本函数 `pub` 出来是因为它是本项目的**可审计性锚点**：任何人可以拿它
/// 独立复核。
pub fn gf256_mul_peasant(a : Int32, b : Int32) -> Int32 {
  let mut x = a & 0xFF
  let mut y = b & 0xFF
  let mut acc = 0
  while y != 0 {
    if (y & 1) == 1 {
      acc = acc ^ x
    }
    x = x << 1
    if (x & 0x100) != 0 {
      x = x ^ 0x11B
    }
    y = y >> 1
  }
  acc & 0xFF
}

///|
/// 生成元明文声明为 3，供文档与测试引用（防止有人悄悄换成别的值）。
pub let gf256_generator : Int32 = 3
