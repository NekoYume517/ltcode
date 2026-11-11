// ============================================================================
// 审计回归（2026-11-12）：`help` 必须与 `accepted_keys` 一致
//
// 现象：`--symbol-len` 被 `simulate` / `curve` / `distcmp` **接受、校验、并回显**
// （错误信息里就写着 `--symbols/--trials/--symbol-len must be >= 1`），但 `help`
// 的三行用法里一个字都没提：
//
//   $ ltcode help
//     ltcode simulate --symbols K --overhead O --trials T [--seed S]
//   $ ltcode simulate --symbols 10 --overhead 1.5 --trials 5 --symbol-len 8
//   simulate  K=10  c=0.10  delta=0.50  trials=5  seed=1  symbol_len=8     # 接受
//   $ ltcode encode --symbols 4 --symbol-len 8 ...
//   ltcode: unknown option '--symbol-len' for encode; run 'ltcode help' ...  # 拒绝
//
// 于是同一个键在三个子命令上可用、在 help 里不可见、在另一条命令上还是用法错误。
// 用户只能从报错文案里反推它存在。README「参数规则」一节把 `accepted_keys`
// （`cmd/ltcode/main.mbt`）称作「一眼可查」的那张表——那么 help 就必须是它的
// 投影，否则这句话不成立。
//
// 这条用例是**防漂移**的：以后再往 `accepted_keys` 里加键而忘了写进 help，
// 它会红。
// ============================================================================

///|
fn usage_line_for(text : String, cmd : String) -> String {
  let needle = "ltcode \{cmd} "
  let padded = "ltcode \{cmd}  "
  for line in text.split("\n") {
    let l = line.to_owned()
    if l.contains(needle) || l.contains(padded) {
      return l
    }
  }
  ""
}

///|
test "help mentions every key that accepted_keys allows" {
  let text = usage()
  for cmd in ["encode", "decode", "simulate", "curve", "distcmp"] {
    let line = usage_line_for(text, cmd)
    assert_true(line.length() > 0)
    for key in accepted_keys(cmd) {
      let want = "--\{key}"
      assert_true(line.contains(want))
    }
  }
}

///|
test "help mentions no key that no subcommand accepts" {
  // 反向：help 里出现的 `--xxx` 必须是某个子命令真的接受的键，
  // 避免 help 承诺一个不存在的选项（比漏写更糟）。
  let text = usage()
  let known : Array[String] = []
  for cmd in ["encode", "decode", "simulate", "curve", "distcmp"] {
    for key in accepted_keys(cmd) {
      if !known.contains(key) {
        known.push(key)
      }
    }
  }
  for line in text.split("\n") {
    let l = line.to_owned()
    let mut i = 0
    while i < l.length() {
      if i + 1 < l.length() &&
        l.get_char(i).unwrap() == '-' &&
        l.get_char(i + 1).unwrap() == '-' {
        // 读到下一个分隔符为止
        let sb = StringBuilder()
        let mut j = i + 2
        while j < l.length() {
          let c = l.get_char(j).unwrap()
          if c == ' ' || c == ']' || c == ',' || c == '<' {
            break
          }
          sb.write_char(c)
          j = j + 1
        }
        let key = sb.to_string()
        if key.length() > 0 {
          assert_true(known.contains(key))
        }
        i = j
      } else {
        i = i + 1
      }
    }
  }
}
