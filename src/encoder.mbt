///|
/// 确定性编码器。
///
/// **核心契约**：编码符号 `i` 的源符号子集只由 `(seed, i, K)` 决定。
/// 因此任意一个符号都能独立重算，不依赖序列 —— 这是 rateless 性质的
/// 实现落点：接收方丢掉中间一段，两端的符号仍然有效；要补发，只需继续给
/// 新的 index。
///
/// 子集抽取用 **Floyd 算法**（`floyd_subset`）：
///
/// ```
/// S = {}
/// for j = K-d .. K-1:
///     t = randint(0..j)
///     if t in S: S = S ∪ {j}  else S = S ∪ {t}
/// ```
///
/// 为什么不用部分 Fisher-Yates：后者需要一块长度 K 的下标数组，K 上万时
/// 每个符号都重分配一次。Floyd 只用 O(d) 内存（d 通常远小于 K，实测平均
/// 度数 10.25 对 K=1000），而且**同样严格均匀**（每个 d 元子集等概率），
/// 这一点由 `encoder_test.mbt` 的枚举验证锁定，而不是口头声明。

///|
/// 一次编码会话：绑定源块、种子与度数分布。
///
/// 持有 `Distribution` 是为了复用它的 CDF 表 —— `sample_degree` 每次调用
/// 都会重建 O(K) 的表，循环里用它会退化成 O(count·K)。
pub(all) struct Encoder {
  seed : UInt64
  block : SourceBlock
  dist : Distribution
}

///|
/// 构造编码器。`c` 与 `δ` 是鲁棒孤波参数，必须与解码端一致
/// （它们决定子集抽样，不是"只影响性能的旋钮"）。
pub fn Encoder::new(
  block : SourceBlock,
  seed : UInt64,
  c : Double,
  delta : Double,
) -> Result[Encoder, LtError] {
  match robust_soliton_checked(block.k, c, delta) {
    Ok(dist) => Ok({ seed, block, dist, })
    Err(e) => Err(e)
  }
}

///|
/// 由 `(seed, index)` 派生这一符号专属的 PRNG。
///
/// **不能用 `splitmix64(seed ^ index)`**。这不是风格问题，是一个实测到的
/// 真实缺陷：`seed ^ index` 只在低位翻转时（例如 seed=1 的相邻 index
/// 0,1,2,...，或相邻种子之间的同一 index），异或后的值彼此只差几个低位，
/// 而 `splitmix64` 虽然会扩散这些位，却让**度数采样用的第一个随机数**在
/// 相邻 `seed ^ index` 之间落进同一段 CDF 区间 —— 结果是「用相邻种子跑
/// 100 次试验」等价于「用同一个种子跑 100 次」，试验之间根本不独立。
///
/// 实测证据（`docs/implementation.md` 第 5 节）：K=1000、overhead=1.17、
/// 每块 200 次试验的 10 个块，用 `seed ^ index` 时块间标准差是 **0.350**，
/// 而二项分布对 n=200 只允许 **0.034**；换成下面的两轮混合后，块间标准差
/// 降到 **0.021**，与二项噪声一致。
///
/// 修法：先把 `seed` 与 `index` **分别**过一遍 splitmix64（各自扩散到全 64 位），
/// 再用一次异或合并，最后再过一遍 splitmix64。这样相邻的 index 或相邻的 seed
/// 都会让派生状态彻底不同。
pub fn symbol_rng(seed : UInt64, index : Int32) -> Ltrng {
  let mixed = splitmix64(
    splitmix64(seed) ^ splitmix64(index.to_uint64() + 0x9E3779B97F4A7C15UL),
  )
  Ltrng::new(mixed)
}

///|
/// 无放回抽取 `d` 个互不相同的下标，取值在 `[0, k)`。结果**升序**返回。
///
/// 升序有两个作用：让子集有唯一表示（便于断言与缓存），以及让 XOR 的累加
/// 顺序固定 —— 虽然 XOR 可交换，但固定顺序让「同参数两次编码逐字节相同」
/// 这条测试不依赖浮点/哈希的偶然行为。
pub fn floyd_subset(rng : Ltrng, k : Int32, d : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  if k <= 0 || d <= 0 {
    return out
  }
  let dd = if d > k { k } else { d }
  // 小 d 直接用哈希集合；Floyd 的 `t in S` 判断需要它。
  let chosen : Map[Int32, Unit] = Map([])
  for j = k - dd; j < k; j = j + 1 {
    let t = rng.next_below(j + 1)
    if chosen.contains(t) {
      chosen[j] = ()
      out.push(j)
    } else {
      chosen[t] = ()
      out.push(t)
    }
  }
  out.sort()
  out
}

///|
/// 给定 `(seed, index)` 与分布，算出该编码符号包含的源符号下标。
/// 解码端用**同一个函数**重建子集 —— 不允许有两份实现。
pub fn subset_for(
  seed : UInt64,
  index : Int32,
  k : Int32,
  dist : Distribution,
) -> Array[Int32] {
  let rng = symbol_rng(seed, index)
  let d = dist.sample(rng)
  floyd_subset(rng, k, d)
}

///|
/// 生成编码符号 `index`。输出长度恒等于 `block.symbol_len`。
///
/// 实现要点：先取第一个源符号的内容作为累加初值（避免先分配零块再 XOR），
/// 之后对子集里其余符号做原地 XOR。子集非空恒成立（`d >= 1`）。
pub fn Encoder::symbol(self : Encoder, index : Int32) -> Symbol {
  let idx = subset_for(self.seed, index, self.block.k, self.dist)
  let work : FixedArray[Byte] = FixedArray::make(self.block.symbol_len, b'\x00')
  for j in idx {
    xor_into(work, self.block.sources[j])
  }
  { index, data: Bytes::from_array(work), }
}

///|
/// 批量生成 `count` 个编码符号，序号从 `first_index` 起。
///
/// `first_index` 存在的意义：接收方在丢包后要「接着发」，序号不能重头开始 ——
/// 重复的 index 意味着重复的方程，对剥皮没有任何帮助。
pub fn Encoder::symbols(
  self : Encoder,
  first_index : Int32,
  count : Int32,
) -> Array[Symbol] {
  let out : Array[Symbol] = []
  for i = 0; i < count; i = i + 1 {
    out.push(self.symbol(first_index + i))
  }
  out
}

///|
/// **PLAN.md §5 规定的入口**：`encode_symbol(seed, index, sources) -> Bytes`。
///
/// 它每次重建分布与分组，因此是 O(K) 的；批量场景请用 `Encoder`。
/// 保留它是因为契约要求一个「只要给参数就能算」的纯函数 —— 测试与外部
/// 复核用例更愿意用这种形状。
///
/// 源符号长度不齐时抛 `SymbolLengthMismatch`；空源抛 `EmptySource`。
pub fn encode_symbol(
  seed : UInt64,
  index : Int32,
  sources : Array[Bytes],
) -> Bytes raise LtError {
  match SourceBlock::new(sources) {
    Err(e) => raise e
    Ok(block) =>
      // 用 PLAN 默认参数建分布（c=0.1, δ=0.5）
      match Encoder::new(block, seed, default_c(), default_delta()) {
        Err(e) => raise e
        Ok(enc) => enc.symbol(index).data
      }
  }
}

///|
/// 默认种子。**一个固定的常数，不是随机数**。
///
/// 理由：本项目的可复现性契约要求「不给出种子时行为也确定」。如果默认
/// 种子来自时钟，`ltcode encode` 两次运行会给出不同文件，README 里的每个
/// 数字都会变成「某次运行的结果」。这个值本身没有神秘含义，
/// 只是 splitmix64 的一个非零输入；有测试锁定它。
pub fn default_seed() -> UInt64 {
  0x4C54434F4445UL
}

///|
/// 默认的鲁棒孤波 `c`。取 0.1 是 LT 文献里的常见起点，本项目的实测曲线
/// 就是在这个值下跑出来的（README）。改动它会让 README 的数字失效，
/// 因此有测试锁定这个值。
pub fn default_c() -> Double {
  0.1
}

///|
/// 默认的 `δ`（目标解码失败概率上界）。同样被测试锁定。
pub fn default_delta() -> Double {
  0.5
}
