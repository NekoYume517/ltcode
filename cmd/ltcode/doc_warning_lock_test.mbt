///|
/// 「警告数不许手写」回归锁（LT40，2026-11-28 审计）。
///
/// ## 现象（LT39 留下的尾巴）
///
/// LT39（2026-11-27）锁住了测试条数，但**警告数仍是手抄的**：
///
/// ```text
/// README.md:486            moon check            # 826 warnings, 0 errors
/// docs/DEMO.md:42          ... now up to date (826 warnings, 0 errors)
/// ```
///
/// 那个 826 是 2026-11-27 那台机器、那版工具链上的一次实测值。它和测试条数
/// 有本质区别：
///
/// - **测试条数**是**源码树的不变量**。`^test "` 的条数只由 `.mbt` 文件的内容
///   决定，任何人 clone 下来数一遍都是同一个数。所以它可以（也应该）被锁。
/// - **警告数**是**工具链 + 配置的因变量**。同一个 commit，换 `moonc` 版本、
///   换 `moon check` 的默认 lint 集、甚至换一个 `.mbti` 的生成时机，这个数就
///   变。它甚至不是"本仓的属性"，是"这次运行的属性"。
///
/// 把后者写成 README 的一个数字，等于承诺一件自己控制不了的事。HANDOVER
/// 已经记录过它漂过多次（721 → 759 → 762 → 785 → 794 → 826），每次都要
/// 人肉重跑、手抄。这是**结构性**的漂移源，不是疏忽。
///
/// ## 选定方案：删掉精确值，改写成「见 CI」
///
/// 二选一里选了**去掉具体数字**，理由：
///
/// 1. 备选方案是"用一个静态可算的代理指标（如 `pub` 项数）去锁"。但那需要
///    在测试里把代理指标和真实警告数挂上钩 —— 而"重跑前端才知道真实值"正是
///    要避免的递归。代理指标一旦和真实值脱钩，它就从"防漂移"退化成
///    "又一个需要人肉同步的数字"。
/// 2. 真正要防的不是"数字过时"，而是"**文档声称一件它无法保证的事**"。
///    删掉精确值时，这个缺陷从根上消失；换成代理指标时，它只是换了个人来
///    承担。
/// 3. 读者拿到 0 error 就够了 —— 警告数是给维护者看的内部信号，`moon check`
///    一条命令就能得到**当次**的准确值。写死在文档里反而会让人以为
///    "826 是这条命令应有的输出"，从而把一个正常的工具链差异误判成回归。
///
/// ## 这条测试锁什么
///
/// 它扫描 `README.md` 与 `docs/DEMO.md` 的正文，发现「N warnings」或
/// 「N 条警告」这类**精确警告数断言**就红。`docs/DEMO.md` 开头的复测年表
/// （以 `> 2026-` 起头）属于「当时确实测到过」的历史记录，予以豁免。
/// DEMO 的 §1 代码块是最容易被当成"当前应有输出"的地方，那里一并禁掉。

///|
/// 读一个文件；读不到直接 abort。
fn lt40_read(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => abort("LT40 lock cannot read '\{path}'")
  }
}

///|
/// 判断一行是不是「精确警告数断言」，命中时返回那个数字（便于报错点名）。
///
/// 命中条件：同一行里出现 `warnings`（或 `条警告`），并且后面还有至少两位的
/// 十进制数。历史年表行以 `> 20` 起头，豁免。
fn lt40_warning_number(line : StringView) -> Int32? {
  // 复测年表的两种行型：`> 2026-…`（新条目）与 `> 实测…` / `> \`moon check\`…`
  // / `> 测试总数…`（条目内的续行）。它们记录的是「当时确实测到过」，不是
  // 对当前状态的断言，豁免。
  let is_history = line.has_prefix("> 20") ||
    line.has_prefix("> 实测") ||
    line.has_prefix("> `moon check`") ||
    line.has_prefix("> 测试总数")
  if is_history {
    return None
  }
  if !line.contains("warnings") && !line.contains("条警告") {
    return None
  }
  // 找第一个 >= 2 位的数字
  let mut num = -1
  let mut digits = 0
  for c in line.to_array() {
    let code = c.to_int()
    if code >= 48 && code <= 57 {
      if num < 0 {
        num = 0
      }
      num = num * 10 + (code - 48)
      digits = digits + 1
    } else {
      if digits >= 2 {
        return Some(num)
      }
      num = -1
      digits = 0
    }
  }
  if digits >= 2 {
    return Some(num)
  }
  None
}

///|
/// **LT40-a**：README 不得再出现精确警告数。
///
/// 修复前 `README.md` 的验证块就是 `moon check  # 826 warnings, 0 errors`。
test "LT40: README no longer asserts an exact moon check warning count" {
  let root = lt39_repo_root()
  let readme = lt40_read("\{root}/README.md")
  let offenders : Array[String] = []
  let mut lineno = 0
  for line in readme.split("\n") {
    lineno = lineno + 1
    if lt40_warning_number(line) is Some(n) {
      offenders.push("\{lineno}: \{n} <- \{line.trim()}")
    }
  }
  if !offenders.is_empty() {
    let sb = StringBuilder::new()
    for o in offenders {
      sb.write_string("\n  ")
      sb.write_string(o)
    }
    abort(
      "README 仍把精确警告数写成事实（应改成「见 CI」）：\{sb}",
    )
  }
}

///|
/// **LT40-b**：`docs/DEMO.md` 的 §1 代码块不得出现精确警告数。
///
/// 只查 §1（`## 1.` 到下一个 `## `），因为那是"当前应有输出"的展示区。
/// 开头的复测年表是历史，由 `lt40_warning_number` 的 `> 20` 豁免覆盖。
test "LT40: DEMO section 1 no longer asserts an exact warning count" {
  let root = lt39_repo_root()
  let demo = lt40_read("\{root}/docs/DEMO.md")
  let mut in_s1 = false
  let mut lineno = 0
  let offenders : Array[String] = []
  for line in demo.split("\n") {
    lineno = lineno + 1
    if line.has_prefix("## 1.") {
      in_s1 = true
      continue
    }
    if in_s1 && line.has_prefix("## ") {
      in_s1 = false
      continue
    }
    if in_s1 {
      if lt40_warning_number(line) is Some(n) {
        offenders.push("\{lineno}: \{n} <- \{line.trim()}")
      }
    }
  }
  if !offenders.is_empty() {
    let sb = StringBuilder::new()
    for o in offenders {
      sb.write_string("\n  ")
      sb.write_string(o)
    }
    abort(
      "DEMO §1 仍断言精确警告数（读者会当成「应有输出」）：\{sb}",
    )
  }
}

///|
/// **LT40-c**：`docs/DEMO.md` 年表**以外**的正文也不许出现精确警告数。
///
/// a 只查 README、b 只查 §1。§3/§9/结尾这些地方也可能顺手写一个数字，
/// 这里一并扫掉（年表行由 `> 20` 前缀豁免）。
test "LT40: DEMO's non-history warning mentions carry no exact number" {
  let root = lt39_repo_root()
  let demo = lt40_read("\{root}/docs/DEMO.md")
  let offenders : Array[String] = []
  let mut lineno = 0
  for line in demo.split("\n") {
    lineno = lineno + 1
    if lt40_warning_number(line) is Some(n) {
      offenders.push("\{lineno}: \{n} <- \{line.trim()}")
    }
  }
  if !offenders.is_empty() {
    let sb = StringBuilder::new()
    for o in offenders {
      sb.write_string("\n  ")
      sb.write_string(o)
    }
    abort("DEMO 正文仍出现精确警告数：\{sb}")
  }
}
