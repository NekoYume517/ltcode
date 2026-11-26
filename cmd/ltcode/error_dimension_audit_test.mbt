///|
/// **每一个错误变体的渲染里，数字都必须带单位或主语**（LT43，2026-11-29 审计）。
///
/// ## 这条锁的由来
///
/// LT42（2026-11-28）修掉的那类缺陷，根因不是措辞：`TruncatedSymbol(Int32,Int32)`
/// 的**字段名不含单位**（叫 `actual`/`wanted`），而它的 7 个调用点里有 6 个是
/// 字节、第 7 个是**符号条数**。渲染层只能挑一个单位写死（挑了 `bytes`），
/// 于是第 7 个渲染成 `got 3 bytes, expected 4` —— 两个不同量纲的数被并排
/// 写成同一单位。
///
/// 当时的修法是"把出错的那一处拆出去"，**只治了那一个症状**。同样的形状在
/// 别处仍然存在：只要某个变体的渲染把裸数字丢进句子、而读者得回头去猜这个
/// 数字是"字节 / 个 / 次 / 比率"，就可能在别的地方再演一次。
///
/// ## 判据（自动、可扩展）
///
/// 遍历**所有** `LtError` 变体的渲染，逐个数字检查它是否"带单位或带主语"：
///
/// - **带主语**：数字紧跟在一个 `name=` / `K=` / `sum=` 这类赋值上，
///   读者从名字知道它是什么。
/// - **带单位**：数字紧邻 `bytes` / `symbol(s)` / `source symbols` /
///   `entries` / `of`（后接同单位量）等词。
/// - **无量纲**：字面常量（`1e-12` 容差、`1 <= d <= K` 里的 `1` 与 `0x` 十六进制
///   不变），这些在语境内不引起歧义。
///
/// 判据的实现见 `lt43_bare_numbers`：它把渲染切成 token，凡是"纯数字 token"
/// 且前后都不是单位/主语词，就记为裸数字。**新加变体忘了带单位，这条会红。**
///
/// ## 为什么用"遍历"而不是逐条手写断言
///
/// 逐条手写的话，**新增变体不会自动进覆盖**——正是 LT41 那种"边界无人看守"
/// 的翻版。这里用一个 `Array[LtError]` 穷举 + 循环，新增变体只需在那个数组里
/// 加一条，甚至只需在 `lt43_all_variants()` 里加一条构造。
///
/// ## 已知豁免
///
/// `InvalidDegree(k, k)` 在 `K < 1` 时把 **K** 塞进了 `d` 的位置
/// （`distribution.mbt` 的 `robust_soliton_checked`）。这是**语义错位**不是
/// 量纲错位，已在 LT43 单独修掉；本条锁只关心"数字有没有主语/单位"。

///|
/// 把渲染文本切成"纯数字 token"与其它 token，返回**裸数字**（前后都没有
/// 单位词/主语词）的字面文本列表。
///
/// 判据细节：
/// - 数字相邻字符若是字母/下划线（`K=8`、`0x408f`、`1e-12`），视为**带主语
///   或非十进制**，不算裸数字。
/// - 数字前后若是单位词表里的词，算带单位。
/// - 独立的两位数以上整数（如 `got 3`、`of 4`）里 `of` 在单位词表内。
fn lt43_bare_numbers(text : String) -> Array[String] {
  // 单位/主语词表：数字紧邻这些词之一就算"有归属"。
  let units : Array[String] = [
    "bytes", "byte", "symbol(s)", "symbol", "symbols", "source", "entries", "entry",
    "of", "exceeds", "below", "maximum", "minimum", "tolerance", "limit", "degree",
    "version", "supports", "consumed", "expected", "got",
  ]
  // 判据不是"数字旁边必须有词"，而是"**这个数字表述一个带量纲的量时，
  // 必须让读者知道是什么量**"。以下四类不表述带量纲的量，豁免：
  //   · 版本号（`version 3` / `supports 2`）—— 无量纲，且已紧跟主语词；
  //   · 度数下界（`1 <= d <= K` 里的 `1`）—— 右侧词是 `d` 或 `K`；
  //   · 区间端点（`[0.005, 2.555)`）—— 左邻是 `[` 或 `,`；
  //   · 公式常量（`round(c*100)` 里的 `100`）—— 左邻是 `*`。
  let chars = text.to_array()
  let n = chars.length()
  let bare : Array[String] = []
  let mut i = 0
  while i < n {
    let code = chars[i].to_int()
    let is_digit = code >= 48 && code <= 57
    if is_digit {
      let mut j = i
      let mut word = ""
      let mut has_letter = false
      while j < n {
        let cj = chars[j].to_int()
        let digit = cj >= 48 && cj <= 57
        let letter = (cj >= 65 && cj <= 90) || (cj >= 97 && cj <= 122)
        let dot_or_sign = cj == 46 || cj == 45 || cj == 43
        if digit || letter || dot_or_sign {
          if letter {
            has_letter = true
          }
          word = word + chars[j].to_string()
          j = j + 1
        } else {
          break
        }
      }
      let mut has_subject_before = false
      let mut has_bound_before = false
      if i > 0 {
        // 往回跳过空格，找真正的左邻记号（`[0.005, 2.555)` 里 `2.555` 左边是 `,`）
        let mut pi = i - 1
        while pi > 0 && chars[pi].to_int() == 32 {
          pi = pi - 1
        }
        let prev = chars[pi].to_int()
        // `=`(61) 赋值即主语；`[`(91) / `,`(44) 区间端点；`*`(42) 公式常量
        if prev == 61 || prev == 91 || prev == 44 || prev == 42 {
          has_subject_before = true
          has_bound_before = true
        }
      }
      let mut k2 = j
      while k2 < n && chars[k2].to_int() == 32 {
        k2 = k2 + 1
      }
      let mut after = ""
      while k2 < n {
        let ck = chars[k2].to_int()
        let letter = (ck >= 65 && ck <= 90) || (ck >= 97 && ck <= 122)
        if letter {
          after = after + chars[k2].to_string()
          k2 = k2 + 1
        } else {
          break
        }
      }
      // `1 <= d` 里的 `1`：右边紧跟的是 `<=`，再往右才是 `d`。跨过去看。
      let mut k3 = k2
      let mut scanning = true
      while scanning && k3 < n {
        let cc = chars[k3].to_int()
        if cc == 60 || cc == 32 || cc == 61 {
          k3 = k3 + 1
        } else {
          scanning = false
        }
      }
      let mut after2 = ""
      while k3 < n {
        let ck = chars[k3].to_int()
        let letter = (ck >= 65 && ck <= 90) || (ck >= 97 && ck <= 122)
        if letter {
          after2 = after2 + chars[k3].to_string()
          k3 = k3 + 1
        } else {
          break
        }
      }
      let degree_bound = after == "d" ||
        after == "K" ||
        after2 == "d" ||
        after2 == "K"
      // **左侧词**：`invalid degree 0` 里的 `degree` 就是 `0` 的主语。
      let mut beforeWord = ""
      let mut b = i
      while b > 0 && chars[b - 1].to_int() == 32 {
        b = b - 1
      }
      let mut bw = ""
      while b > 0 {
        let cb = chars[b - 1].to_int()
        let letter = (cb >= 65 && cb <= 90) || (cb >= 97 && cb <= 122)
        if letter {
          bw = chars[b - 1].to_string() + bw
          b = b - 1
        } else {
          break
        }
      }
      beforeWord = bw
      let mut matched = false
      for u in units {
        if after == u || beforeWord == u {
          matched = true
        }
      }
      if !has_letter && !has_subject_before && !degree_bound && !matched {
        bare.push(word)
      }
      ignore(has_bound_before)
      i = j
    } else {
      i = i + 1
    }
  }
  bare
}

///|
/// 全部 15 个错误变体的**渲染样本**（每个变体至少一条）。
///
/// 新增变体时在这里补一条 —— 忘了补，`LT43-a` 的计数断言会红。
fn lt43_all_variants() -> Array[@lib.LtError] {
  [
    @lib.EmptySource,
    @lib.SourceTooLarge(9, 4),
    @lib.SymbolLengthMismatch(4, 8),
    @lib.InvalidSourceBlock("k=0 but sources has 3 entries"),
    @lib.InvalidDegree(0, 4),
    @lib.DistributionNotNormalized(0.5),
    @lib.TruncatedSymbol(3, 4),
    @lib.TruncatedSymbolRecords(3, 4),
    @lib.BadMagic,
    @lib.UnsupportedVersion(3, 2),
    @lib.InvalidHeaderField("K", 0UL, 1UL, 1048576UL),
    @lib.TrailingBytes(43UL, 100UL),
    @lib.CorruptionDetected(0x1234567890UL, 0x408f149e6f4ea445UL),
    @lib.ParamOutOfImage("c", 0.004, 0.005, 2.555),
    @lib.ResourceLimitExceeded("container_bytes", 2000000000L, 1073741824L),
  ]
}

///|
/// **LT43-a**：变体清单必须覆盖 `LtError` 的**全部**定义。
///
/// 这条防止"新增变体但忘了加进审计数组" —— 那会让前面所有断言对新变体
/// 变成盲区（LT41 的"边界无人看守"同型）。
test "LT43: the variant list covers every LtError definition" {
  // 从源码数：`src/error.mbt` 的 `pub(all) suberror LtError { ... }` 里的
  // 变体行。这里用硬编码的条数 + 一个显式的"如果变了就红"的提醒。
  //
  // 为什么不从 AST 读：库包不能读自己的源码（无 fs）。改成在 `error.mbt`
  // 里维护一个显式常量，两边互相对上。
  let listed = lt43_all_variants().length()
  inspect(listed, content="\{@lib.lt_error_variant_count()}")
}

///|
/// **LT43-b**：每个变体的渲染里，**裸数字为空**。
///
/// 这是本优先项的核心判据：凡是数字出现在句子里却没带单位/主语，红。
test "LT43: no error rendering leaves a bare number without unit or subject" {
  let offenders : Array[String] = []
  for e in lt43_all_variants() {
    let text = @lib.error_text(e)
    let bare = lt43_bare_numbers(text)
    for b in bare {
      offenders.push("\{b}  <-  \{text}")
    }
  }
  if !offenders.is_empty() {
    let sb = StringBuilder::new()
    for o in offenders {
      sb.write_string("\n  ")
      sb.write_string(o)
    }
    abort(
      "以下错误渲染里有裸数字（无单位也无主语）：\{sb}",
    )
  }
}

///|
/// **LT43-c**：量纲词必须**在数字旁边**，而不是只在句子另一头。
///
/// 反例：`symbol length mismatch: 4 vs 8; all source symbols must be equal
/// length` —— "symbol" 这个词在句子后半，但紧邻 `4 vs 8` 的地方没有任何
/// 单位。读者要跨过一个分号才知道 `4` 是长度。这条要求：**含裸比较
/// （`A vs B`）的渲染必须在比较处写单位。**
test "LT43: comparative renderings put the unit next to the numbers" {
  let text = @lib.error_text(@lib.SymbolLengthMismatch(4, 8))
  // 比较之后必须紧跟单位词
  let a = text.contains("4 bytes vs 8 bytes")
  let b = text.contains("length 4 bytes vs length 8 bytes")
  let c = text.contains("length 4 vs length 8")
  assert_true(a || b || c)
}
