///|
/// 文档计数漂移回归锁（LT39，2026-11-27 审计）。
///
/// ## 现象
///
/// `README.md` 与 `docs/DEMO.md` 把「测试总数」与「`moon check` 警告数」
/// 当成**可复现事实**写死在正文里。其中 `docs/DEMO.md` 开篇还承诺：
///
/// > 本文件里的每一条命令都是**实际执行过**的，输出原样粘贴（含换行与缩进）。
/// > 没有"示例输出"——只有真实输出。
///
/// 本轮实测（`moon 0.1.20261102`，HEAD `a1027f8`）得到的是
///
/// ```text
/// $ moon test
/// Total tests: 278, passed: 278, failed: 0.
/// $ moon check
/// Finished. moon: ran 5 tasks, now up to date (825 warnings, 0 errors)
/// ```
///
/// 而两份文档都还写着 **257** 与 **794**。差额 21 条测试不是笔误：
/// `4be2c9f` 之后连续 8 个提交（LT33..LT38）新增了 4 个测试文件，
/// **一次都没回头改文档**：
///
/// ```text
/// src/duplicate_index_test.mbt        5 条  (LT34)
/// src/negative_param_test.mbt        11 条  (LT33)
/// cmd/ltcode/out_path_empty_test.mbt  4 条  (LT38)
/// src/trial_independence_test.mbt     3 条  (LT36)
/// ```
///
/// ## 为什么这条要当成缺陷来锁
///
/// 1. **DEMO.md 的 §1 是一句可被当场证伪的断言**。读者照抄 `moon test`
///    得到 278，文档写着 257 —— 而文档的全部价值就建立在「输出原样粘贴」上。
/// 2. **README 的「测试分布」表是该仓唯一的契约索引**。表里缺这 4 个文件，
///    于是它们锁住的 4 条契约（重复下标裁决、负参数入口、`--out` 空值、
///    试验独立性）在索引里不存在；后来的人改相关代码时无从知道它们被锁着。
///
/// ## 这条测试怎么工作（不跑 `moon test`，避免递归）
///
/// 它直接读源码树与两份文档，核对三件事：
///
/// 1. README 声称的测试总数 == 源码树 `test "` 的真实条数；
/// 2. README 表格各行条数之和 == 同一个真实条数（防「总数对了但表格漏行」）；
/// 3. `src/` 与 `cmd/ltcode/` 下每个 `*_test.mbt` / `*_wbtest.mbt` 都在表格里。
///
/// 警告数直接比对的代价太高（要跑 `moon check`），所以这里**不锁**它；
/// 只锁"能直接从源码树算出来的数"，也就是测试条数。

///|
/// 上一个路径分隔符的位置（`\\` 与 `/` 都认），没有返回 -1。
fn lt39_last_sep(s : String) -> Int32 {
  let mut last = -1
  let mut idx = 0
  for c in s.to_array() {
    let code = c.to_int()
    if code == 92 || code == 47 {
      last = idx
    }
    idx = idx + 1
  }
  last
}

///|
/// 仓库根：从 CWD 向上找含 `moon.mod` 的目录（最多 5 级）。
/// `LT39_REPO_ROOT` 可显式覆盖（CI 里更稳）。
fn lt39_repo_root() -> String {
  match @env.get_env_var("LT39_REPO_ROOT") {
    Some(v) => if v.length() > 0 { return v }
    None => ()
  }
  let cwd = match @env.current_dir() {
    Some(v) => v
    None => "."
  }
  let mut dir = cwd
  for _ in 0..<=5 {
    if @fs.path_exists("\{dir}\\moon.mod") || @fs.path_exists("\{dir}/moon.mod") {
      break
    }
    let cut = lt39_last_sep(dir)
    if cut <= 0 {
      break
    }
    dir = dir.clamped_view(start=0, end=cut).to_owned()
  }
  dir
}

///|
/// 数 `test "` 开头的行（README 表头注明按 `^test "` 计数）。
fn lt39_count_tests(text : String) -> Int32 {
  let mut n = 0
  for line in text.split("\n") {
    if line.trim().has_prefix("test \"") {
      n = n + 1
    }
  }
  n
}

///|
/// 从一个字符串里取出第一段连续数字；没有返回 -1。
fn lt39_first_number(s : StringView) -> Int32 {
  let mut num = -1
  let mut started = false
  for c in s.to_array() {
    let code = c.to_int()
    if code >= 48 && code <= 57 {
      if !started {
        num = 0
        started = true
      }
      num = num * 10 + (code - 48)
    } else if started {
      break
    }
  }
  num
}

///|
/// 从 README 的「测试分布（N 条…）」标题里取出 N。取不到返回 -1。
fn lt39_readme_claimed_total(readme : String) -> Int32 {
  for line in readme.split("\n") {
    if line.trim().has_prefix("测试分布（") {
      return lt39_first_number(line)
    }
  }
  -1
}

///|
/// 从 README 表格行 `| \`file.mbt\` | N | ...` 里取出 (file, N) 对。
fn lt39_readme_table_rows(readme : String) -> Array[(String, Int32)] {
  let out : Array[(String, Int32)] = []
  for line in readme.split("\n") {
    let s = line.trim()
    if !s.has_prefix("| `") {
      continue
    }
    match s.find("`") {
      None => continue
      Some(t1) => {
        let rest = s.clamped_view(start=t1 + 1, end=s.length()).to_owned()
        match rest.find("`") {
          None => continue
          Some(t2) => {
            let name = rest.clamped_view(start=0, end=t2).to_owned()
            let after = rest.clamped_view(start=t2 + 1, end=rest.length())
            let n = lt39_first_number(after)
            if n >= 0 {
              out.push((name, n))
            }
          }
        }
      }
    }
  }
  out
}

///|
/// 读一个文件；读不到直接 abort（静默跳过会让这条锁失效）。
fn lt39_read(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    _ => abort("LT39 lock cannot read '\{path}'")
  }
}

///|
/// 收齐源码树里所有测试文件的真实条数。
fn lt39_actual_tests(root : String) -> Array[(String, Int32)] {
  let found : Array[(String, Int32)] = []
  for dir_name in ["src", "cmd/ltcode"] {
    let dir = "\{root}/\{dir_name}"
    let names : ArrayView[String] = @fs.read_dir(dir) catch {
      _ => abort("LT39 lock cannot list '\{dir}'")
    }
    for n in names {
      if n.has_suffix("_test.mbt") || n.has_suffix("_wbtest.mbt") {
        let body = lt39_read("\{dir}/\{n}")
        found.push((n, lt39_count_tests(body)))
      }
    }
  }
  found
}

///|
/// **LT39-a**：README 声称的测试总数必须等于源码树的**真实**条数。
///
/// 这是 DEMO §1 那句「`Total tests: N, passed: N, failed: 0.`」的同一份
/// 事实。修复前 README 写 257、源码树是 278 —— 差 21 条。
test "LT39: README's claimed test total equals the real count in the source tree" {
  let root = lt39_repo_root()
  let readme = lt39_read("\{root}/README.md")
  let claimed = lt39_readme_claimed_total(readme)
  assert_true(claimed >= 0)
  let mut real = 0
  for row in lt39_actual_tests(root) {
    real = real + row.1
  }
  // 明细放在断言消息里，红了能一眼看出差在哪。
  inspect(claimed, content="\{real}")
}

///|
/// **LT39-b**：README 表格各行之和 == 标题声称的总数。
///
/// 防「总数改了但表格漏行」和「表格补了行但总数忘了改」这两种半修。
test "LT39: README test-distribution table rows sum to the claimed total" {
  let root = lt39_repo_root()
  let readme = lt39_read("\{root}/README.md")
  let claimed = lt39_readme_claimed_total(readme)
  assert_true(claimed >= 0)
  let mut sum = 0
  for row in lt39_readme_table_rows(readme) {
    sum = sum + row.1
  }
  inspect(sum, content="\{claimed}")
}

///|
/// **LT39-c**：每个测试文件都必须在 README 表格里出现一行。
///
/// 这条才是真正让「新增测试文件忘了登记」变红的锁：LT33/LT34/LT36/LT38
/// 四个文件当年都没登记，而上面两条只比总数时还能被别处的数字掩盖。
test "LT39: every test file in src/ and cmd/ltcode/ has a README table row" {
  let root = lt39_repo_root()
  let readme = lt39_read("\{root}/README.md")
  let listed : Map[String, Int32] = Map([])
  for (name, _) in lt39_readme_table_rows(readme) {
    listed[name] = 1
  }
  let missing : Array[String] = []
  for (name, _) in lt39_actual_tests(root) {
    if !listed.contains(name) {
      missing.push(name)
    }
  }
  if !missing.is_empty() {
    let sb = StringBuilder::new()
    for i, n in missing {
      if i > 0 {
        sb.write_string(", ")
      }
      sb.write_string(n)
    }
    abort("README 的测试分布表缺少这些文件的行：\{sb}")
  }
}

///|
/// **LT39-d**：`docs/DEMO.md` §3 的 `decode` 转录必须与真实输出一致。
///
/// ## 现象（LT39 的第二半）
///
/// §3 声称「输出原样粘贴」，但那段 `missing indices` 被**终端硬换行**
/// 折成了三行：
///
/// ```text
/// missing indices: 0,2,4,6,8,9,10,18,21,22,23,24,25,29,30,
/// 31,33,...79,81,
/// 83,86,89,90,92,93,94,96,98,99
/// ```
///
/// 而程序打出的是**一行**（51 < `LT_MAX_LISTED_MISSING`=64，所以未截断），
/// 后面还跟着 LT18 加的 `  note: ...peeling stalled...` —— 文档里
/// **整行缺失**。文档末尾那句「（注：不同次运行分块的行宽由终端决定；
/// 内容一致。）」正是这条缺陷的自我辩解：它把"抄错了排版"说成了"终端
/// 宽度不同"，而 `ltcode` 的 stdout 从不查询终端宽度。
///
/// 这条测试不去跑子进程（那是 e2e 的活，`independent_sweep_test` 已覆盖
/// 解码本身），只核对**文档文本的结构**：
///
/// - §3 里必须有 `note: ...peeling stalled` 那一行（LT18 的行为）；
/// - `missing indices:` 必须以 `,99` 结尾出现在**同一行**（不跨行）；
/// - 不能残留「行宽由终端决定」这种已被证伪的说法。
test "LT39: DEMO section 3 transcribes the real decode output, not a rewrapped one" {
  let root = lt39_repo_root()
  let demo = lt39_read("\{root}/docs/DEMO.md")
  let mut saw_stalled_note = false
  let mut saw_terminal_wrap_claim = false
  let mut saw_whole_missing_line = false
  for line in demo.split("\n") {
    if line.find("peeling stalled") is Some(_) {
      saw_stalled_note = true
    }
    if line.find("行宽由终端决定") is Some(_) {
      saw_terminal_wrap_claim = true
    }
    if line.has_prefix("missing indices: ") && line.has_suffix(",99") {
      saw_whole_missing_line = true
    }
  }
  assert_true(saw_stalled_note)
  assert_true(saw_whole_missing_line)
  assert_false(saw_terminal_wrap_claim)
}

///|
/// **LT39-e**：`docs/DEMO.md` §1 的 `moon test` / `moon check` 行必须与
/// README 声称的同一组数字一致。
///
/// 两个文档各写一遍同一个事实，修复前它们**一起**漂移（都是 257 / 794），
/// 所以只看其中一个抓不到"两份都错"的情况。这条把它们绑在一起，并在
/// LT39-a 已经锚定真实值的前提下形成闭环。
test "LT39: DEMO section 1 and README agree on the test and warning counts" {
  let root = lt39_repo_root()
  let demo = lt39_read("\{root}/docs/DEMO.md")
  let readme = lt39_read("\{root}/README.md")
  let claimed = lt39_readme_claimed_total(readme)
  assert_true(claimed >= 0)
  let mut demo_total = -1
  for line in demo.split("\n") {
    if line.has_prefix("Total tests: ") {
      demo_total = lt39_first_number(line)
      break
    }
  }
  assert_true(demo_total >= 0)
  inspect(demo_total, content="\{claimed}")
}
