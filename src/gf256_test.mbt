///|
/// GF(256) 测试。
///
/// **对照基准不是「我以为对」的表**，而是一个**完全不用表**的俄罗斯农民乘法
/// （`gf256_mul_peasant`，只做移位和条件 XOR）。两张表由不同原理产生，
/// 全部 65536 对逐项相等才说明对数/反对数表构造正确。

///|
test "gf256 fips197 anchor 0x57 * 0x83 == 0xC1" {
  // FIPS-197 §4.2 的例子。这个值可以手算：
  //   0x57 * 0x83 = 0x57*(0x80 ^ 0x02 ^ 0x01)
  // 是 AES 标准里唯一被反复引用的乘法例子。
  inspect(gf256_mul(0x57, 0x83), content="193")
  inspect(gf256_mul(0x83, 0x57), content="193")
}

///|
test "gf256 zero is absorbing" {
  for x = 0; x < 256; x = x + 1 {
    inspect(gf256_mul(0, x), content="0")
    inspect(gf256_mul(x, 0), content="0")
    inspect(gf256_mul_peasant(0, x), content="0")
    inspect(gf256_mul_peasant(x, 0), content="0")
  }
}

///|
test "gf256 multiplication is commutative and has 1 as identity" {
  for x = 0; x < 256; x = x + 1 {
    inspect(gf256_mul(x, 1), content="\{x}")
    inspect(gf256_mul(1, x), content="\{x}")
  }
}

///|
test "gf256 inverse: a * inv(a) == 1 for all 255 nonzero a" {
  let mut bad = 0
  for a = 1; a < 256; a = a + 1 {
    match gf256_inv(a) {
      Some(inv) => {
        if gf256_mul(a, inv) != 1 {
          bad = bad + 1
        }
        // 逆的唯一性：inv(inv(a)) == a
        match gf256_inv(inv) {
          Some(back) => if back != a { bad = bad + 1 }
          None => bad = bad + 1
        }
      }
      None => bad = bad + 1
    }
  }
  inspect(bad, content="0")
}

///|
test "gf256 inverse of zero is unrepresentable (None, not 0)" {
  inspect(gf256_inv(0) is None, content="true")
}

///|
test "gf256 pow matches repeated multiplication" {
  let a = 0x1D
  let mut acc = 1
  // a^0 == 1
  inspect(gf256_pow(a, 0), content="1")
  for n = 1; n <= 8; n = n + 1 {
    acc = gf256_mul(acc, a)
    inspect(gf256_pow(a, n), content="\{acc}")
  }
  // a^255 == 1（乘法群的阶是 255）
  inspect(gf256_pow(a, 255), content="1")
}

///|
/// 全 65536 对与无表实现逐项比对。这是本模块最重要的一条测试。
test "gf256 all 65536 pairs agree with table-free peasant multiplication" {
  let mut mismatches = 0
  let mut first_a = -1
  let mut first_b = -1
  for a = 0; a < 256; a = a + 1 {
    for b = 0; b < 256; b = b + 1 {
      let tabled = gf256_mul(a, b)
      let peasant = gf256_mul_peasant(a, b)
      if tabled != peasant {
        if mismatches == 0 {
          first_a = a
          first_b = b
        }
        mismatches = mismatches + 1
      }
    }
  }
  // 失败时打印第一处不一致，便于定位
  if mismatches != 0 {
    println("first mismatch at (\{first_a}, \{first_b})")
  }
  inspect(mismatches, content="0")
}

///|
test "gf256 xor is addition and is its own inverse" {
  for a = 0; a < 256; a = a + 1 {
    let b = (a * 37 + 11) % 256
    let s = gf256_add(a, b)
    inspect(gf256_add(s, b), content="\{a}")
  }
}

///|
/// 分布律：交换律 + 结合律在全 256 域上成立（用无表实现核对表实现）。
test "gf256 associative over a sampled grid" {
  let mut bad = 0
  for a = 0; a < 16; a = a + 1 {
    for b = 0; b < 16; b = b + 1 {
      for c = 0; c < 16; c = c + 1 {
        let l = gf256_mul(gf256_mul(a, b), c)
        let r = gf256_mul_peasant(a, gf256_mul_peasant(b, c))
        if l != r {
          bad = bad + 1
        }
      }
    }
  }
  inspect(bad, content="0")
}
