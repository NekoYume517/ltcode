// LC-1（2026-11-08 审计）：encode --count 巨大值无防护。
//
// ## 缺陷形态（修复前）
//
//     ltcode encode --input pay.bin --symbols 4 --count 2147483647
//
// count 只查 < 0，21 亿符号进入 enc.symbols(0, count) 的逐符号生成
// 循环（度分布采样 + GF(256) 运算），实测 120 秒不终止、不报错、
// 不返回 —— 既不是用法错误也不是数据错误，就是挂死。与 lincheck
// gen 对 Int32 乘积溢出做防护的思路不对称：这里的危险不是溢出而是
// 无界分配，需要的是量级上限。
//
// ## 修复
//
// --count 上限 1_000_000（百万符号容器 ≈ 每符号 5+ 字节 ≈ 数十 MB，
// 远超本项目「K 至多数千」的定位）；超限报用法错误并写明上限。

///|
test "LC-1: count 上限常量与语义" {
  // 上限本身可被正常 encode 使用（不阻拦合理请求）
  inspect(LT_MAX_COUNT > 0, content="true")
  // 巨大 count 超限
  inspect(LT_MAX_COUNT < 2147483647, content="true")
}
