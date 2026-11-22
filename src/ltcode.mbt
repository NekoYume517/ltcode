///|
/// ltcode — rateless erasure coding.
///
///   gf256        →  field arithmetic used by symbol XOR
///   distribution →  robust soliton degree sampling
///   encoder      →  XOR of d source symbols
///   decoder      →  peeling（无 inactivation；卡住即如实报 Incomplete，
///                    见 README「不做什么」——这是设计选择，注释此前写
///                    "with inactivation fallback" 与实现相反）

///|
pub let version : String = "0.1.0"
