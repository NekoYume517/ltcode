///|
/// 编码文件的自描述容器格式。
///
/// 设计目标：**解码只需要这个文件**。因此头部必须带齐所有解码参数：
/// 魔数、版本、K、seed、symbol_len、payload_len、校验和、符号数。
/// 参数不齐就要「用户再给一次」，那就不是自描述。
///
/// 布局（全部大端，固定字段长度，无变长混淆），**版本 2**：
///
/// ```
/// offset  size  field
///   0      4    magic  = "LTC2"
///   4      1    version = 2
///   5      1    c_q      = round(c * 100)      (0.1  ->  10)
///   6      1    delta_q  = round(delta * 100)  (0.5  ->  50)
///   7      4    K            (u32 BE)
///  11      8    seed         (u64 BE)
///  19      4    symbol_len   (u32 BE)
///  23      8    payload_len  (u64 BE)
///  31      8    payload_hash (u64 BE, FNV-1a of the original payload)
///  39      4    count        (u32 BE)
///  43      ...  count × (index u32 BE, data symbol_len bytes)
/// ```
///
/// ## 为什么要有 `payload_hash`
///
/// 这不是"锦上添花的完整性检查"，它修的是一个**静默数据损坏**：
/// LT 的剥皮在**没有校验和**的情况下，只要收到的符号之间互相矛盾（例如
/// 传输中被改了一个字节），它可能照常"解完"，但解出来的若干源符号是错的。
/// 实测：K=20、overhead=2.0，把**一个度为 1 的符号**改掉一个字节，
/// 解码返回 `Complete`，而 20 个源符号里有 **7 个是错的** ——
/// 调用方拿到的是一份"看起来成功、内容错误"的文件。
///
/// 在裸 LT 上无法从方程组本身发现这一点（度为 1 的符号的累积值**就是**
/// 那个源符号，没有冗余可比对）。因此校验和必须来自**原始的 payload**，
/// 在编码时算好、写进头部；解码后重算并比对，不一致就明确报错。
///
/// 这让 `decode` 满足 PLAN §9 的"成功时恢复原文件并**逐字节校验**"：
/// 校验不是可选项，而是 `Complete` 的定义的一部分（见 CLI 的 `cmd_decode`）。
///
/// 代价：容器多 8 字节，且编码时必须持有原始 payload 才能算哈希。
/// 后者可接受 —— `encode` 本来就是从文件读起的。
///
/// `payload_len` 是**原始字节数**：`SourceBlock::from_bytes` 会把数据切成
/// K 段并在末尾补零，解码后必须按 `payload_len` 截回去，否则文件尾部会多出
/// 一串零字节。这不是「填充掩盖缺失」—— 缺失在 `Incomplete` 里如实报出。
///
/// `c` / `delta` 量化成百分之一：它们只影响子集抽样，量化误差会让编码端与
/// 解码端算出不同的子集。因此**两个方向都必须经过同一个量化函数**
/// （`quantize_param` / `dequantize_param`），而不是各写一次。
///
/// 版本号不匹配时明确报错，不尝试「兼容解析」—— 那会让两种格式静默混淆。
/// 版本 1 → 2 的差别只是多了 `payload_hash` 且魔数变为 "LTC2"：宁可让旧文件
/// 明确地不被接受，也不要让"没有校验和"的东西被当成合法容器。

///|
pub let container_magic : FixedArray[Byte] = [b'L', b'T', b'C', b'2']

///|
pub let container_version : Int32 = 2

///|
/// 头部固定长度。
pub fn header_len() -> Int32 {
  43
}

///|
/// 载荷哈希：FNV-1a 64 位。
///
/// 选 FNV-1a 而不是 CRC32 或 SHA 的理由：**只需要抓住意外损坏**（改字节、
/// 截断、拼接错误），不需要抗恶意构造。FNV-1a 是 10 行实现、无表、
/// 跨端一致（纯整数运算），且 64 位碰撞概率对"意外损坏"这个用途绰绰有余。
///
/// 若要防**主动攻击**（有人故意构造一个哈希相同的 payload），这个哈希
/// 不够 —— 但那不在本项目的能力声明里，README 也不声称它可以。
pub fn payload_hash(data : Bytes) -> UInt64 {
  let mut h = 0xCBF29CE484222325UL
  for i = 0; i < data.length(); i = i + 1 {
    h = h ^ data[i].to_uint64()
    h = h * 0x00000100000001B3UL
  }
  h
}

///|
/// 参数量化：`round(x * 100)`，钳到 `[0, 255]`。
pub fn quantize_param(x : Double) -> Int32 {
  let v = (x * 100.0).round().to_int()
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// 反量化。与 `quantize_param` 严格互逆（在量化后的整数上）。
pub fn dequantize_param(q : Int32) -> Double {
  q.to_double() / 100.0
}

///|
/// 大端写 u32。
fn put_u32(out : Array[Byte], v : Int32) -> Unit {
  let u = v.to_uint()
  out.push(((u >> 24) & 0xFF).to_byte())
  out.push(((u >> 16) & 0xFF).to_byte())
  out.push(((u >> 8) & 0xFF).to_byte())
  out.push((u & 0xFF).to_byte())
}

///|
/// 大端写 u64。
fn put_u64(out : Array[Byte], v : UInt64) -> Unit {
  for shift = 7; shift >= 0; shift = shift - 1 {
    out.push(((v >> (shift * 8)) & 0xFFUL).to_byte())
  }
}

///|
/// 一个大端 u32 的读取位置。
priv struct Reader {
  data : Bytes
  mut pos : Int32
}

///|
/// 大端 u32，**按无符号语义**返回到 `UInt64`。
///
/// 头部里 `K` / `symbol_len` / `count` 都是 u32，而本项目内部一律有符号
/// `Int32`。直接 `u32()` 会让 `0xFFFFFFFF` 变成 `-1`、`0x80000000` 变成
/// `-2147483648`，而这两个值在后续逻辑里会**静默吃掉**符号（`i < count`
/// 一次都不执行）。因此头部的 u32 字段统一先按 u64 原值读出、做域校验，
/// 确认在域内才 `to_int()`。
///
/// 长度检查同样用「剩余字节」形式（见 `Reader::bytes`）：这里只读 4 字节，
/// 但同一族的写法必须一致，否则以后有人「顺手」把它改成变长读取就又回到
/// Int32 回绕那个问题上。
fn Reader::u32_unsigned(self : Reader) -> UInt64 raise LtError {
  let remaining = self.data.length() - self.pos
  if 4 > remaining {
    raise LtError::TruncatedSymbol(remaining, 4)
  }
  let mut v = 0UL
  for i = 0; i < 4; i = i + 1 {
    v = (v << 8) | (self.data[self.pos + i].to_uint64() & 0xFFUL)
  }
  self.pos = self.pos + 4
  v
}

///|
/// 读一个大端 u32。长度检查同样用「剩余字节」形式（见 `Reader::bytes`）。
fn Reader::u32(self : Reader) -> Int32 raise LtError {
  let remaining = self.data.length() - self.pos
  if 4 > remaining {
    raise LtError::TruncatedSymbol(remaining, 4)
  }
  let mut v = 0
  for i = 0; i < 4; i = i + 1 {
    v = (v << 8) | (self.data[self.pos + i].to_int() & 0xFF)
  }
  self.pos = self.pos + 4
  v
}

///|
fn Reader::u64(self : Reader) -> UInt64 raise LtError {
  let remaining = self.data.length() - self.pos
  if 8 > remaining {
    raise LtError::TruncatedSymbol(remaining, 8)
  }
  let mut v = 0UL
  for i = 0; i < 8; i = i + 1 {
    v = (v << 8) | (self.data[self.pos + i].to_uint64() & 0xFFUL)
  }
  self.pos = self.pos + 8
  v
}

///|
fn Reader::byte(self : Reader) -> Int32 raise LtError {
  let remaining = self.data.length() - self.pos
  if 1 > remaining {
    raise LtError::TruncatedSymbol(remaining, 1)
  }
  let v = self.data[self.pos].to_int() & 0xFF
  self.pos = self.pos + 1
  v
}

///|
/// 读 `n` 个字节。
///
/// **长度检查必须先算差再比**（LT-C，2026-11-10 审计）：
///
/// ```moonbit nocheck
/// if n < 0 || self.pos + n > self.data.length()   // ❌ 回绕
/// ```
///
/// `pos = 47`、`n = 0x7FFFFFFF` 时 `pos + n` 在 Int32 上溢出成负数，
/// 比较恒为 false，检查被绕过 → `FixedArray::make(2^31-1)` → `PanicError`
/// （native 退出码 -1073740791 / 0xC0000409）。
///
/// 改成 `n > self.data.length() - self.pos`：右边在 `pos <= length()`
/// 时恒非负且不超过 `Int32` 上限，比较不会回绕。`n < 0` 单独留着，因为
/// 负 `n` 让这个比较为 false。报错携带的也是**剩余 / 请求**两个量，
/// 不用 `pos + n`，免得在报错路径上再溢出一次。
fn Reader::bytes(self : Reader, n : Int32) -> Bytes raise LtError {
  let remaining = self.data.length() - self.pos
  if n < 0 || n > remaining {
    raise LtError::TruncatedSymbol(remaining, n)
  }
  let out : FixedArray[Byte] = FixedArray::make(n, b'\x00')
  for i = 0; i < n; i = i + 1 {
    out[i] = self.data[self.pos + i]
  }
  self.pos = self.pos + n
  Bytes::from_array(out)
}

///|
/// 序列化一个编码文件。
pub fn pack_container(
  block : SourceBlock,
  seed : UInt64,
  payload : Bytes,
  c : Double,
  delta : Double,
  symbols : Array[Symbol],
) -> Bytes {
  let out : Array[Byte] = []
  for m in container_magic {
    out.push(m)
  }
  out.push(container_version.to_byte())
  out.push(quantize_param(c).to_byte())
  out.push(quantize_param(delta).to_byte())
  put_u32(out, block.k)
  put_u64(out, seed)
  put_u32(out, block.symbol_len)
  put_u64(out, payload.length().to_uint64())
  put_u64(out, payload_hash(payload))
  put_u32(out, symbols.length())
  for s in symbols {
    put_u32(out, s.index)
    for i = 0; i < s.data.length(); i = i + 1 {
      out.push(s.data[i])
    }
  }
  Bytes::from_array(out)
}

///|
/// 一个解包出来的容器的全部字段。
#derive(Debug)
pub(all) struct Container {
  k : Int32
  seed : UInt64
  symbol_len : Int32
  payload_len : Int32
  payload_hash : UInt64
  c : Double
  delta : Double
  symbols : Array[ReceivedSymbol]
}

///|
/// 反序列化。任何结构性问题都报明确错误（不猜）。
///
/// ## 头部字段的域校验（LT-A，2026-11-10 审计）
///
/// 头里的 `K` / `symbol_len` / `payload_len` / `count` 在文件里都是**无符号**
/// 字段（u32 / u64），而本项目内部一律用有符号 `Int32`。直接读取会静默
/// 转换出两种坏值：
///
/// - **变负**：`count = 0xFFFFFFFF` → `-1`。`for i = 0; i < count` 一次都不
///   执行，300 个好符号被丢光，于是解码报 `INCOMPLETE: missing 100 of 100`、
///   退出码 1 —— 调用方会去补发符号，而真实原因是"头部说这里有 42 亿个"。
///   这是**误导性的业务状态**，不是损坏、不是用法错误。
/// - **截断**：`payload_len = 2^32 + 5` → `5`。解码"成功"但只写出 5 字节
///   原文，其余被 `reassemble` 截掉（校验和只是碰巧兜住一次，不是保证）。
///
/// 两者都不是崩溃，因此必须显式校验。校验落在 unpack 是因为它是唯一入口：
/// `decode_verified`、CLI、测试都从它进，让每个调用方各自记得查，迟早有人
/// 漏一次。校验用的是**文件自身的剩余字节**，不需要任何外部信息 —— 与
/// 「解码只需要这个文件」这条契约一致。
pub fn unpack_container(data : Bytes) -> Container raise LtError {
  if data.length() < header_len() {
    raise LtError::TruncatedSymbol(data.length(), header_len())
  }
  // 魔数：不是 "LTC2" 说明这**不是** ltcode 容器，与"被截断"是两件事
  for i = 0; i < 4; i = i + 1 {
    if data[i] != container_magic[i] {
      raise LtError::BadMagic
    }
  }
  let r = Reader::{ data, pos: 4, }
  let version = r.byte()
  if version != container_version {
    // 版本不符：明确报错而不是尽力解析，也不借用无关的错误变体
    raise LtError::UnsupportedVersion(version, container_version)
  }
  // `c` / `delta` 的域校验（LT3，2026-11-13 审计）。
  //
  // 这两个字段是头部里**唯一**没有域校验的两个，修复前它们的越界被原样交给
  // `robust_soliton_checked`，于是 decode 报出来的是**分布的错**：
  //
  //   c_q = 0        → decode error: degree distribution is not normalized: sum=0
  //   delta_q = 101  → decode error: degree distribution is not normalized: sum=1.01
  //
  // 文案指错了对象：用户从来没有给过「度数分布」，那两个 `sum=` 数字是分布表的
  // 求和，从它们倒推不出"第 5/6 个字节坏了"。与 LT-2（魔数/版本从
  // `TruncatedSymbol` / `SourceTooLarge` 拆出来）、LT-G（K 变负从
  // `EmptySource` 拆出来）、LT-A（count / payload_len 补域）、LT-D（尾部）
  // 同族：**头部字段的问题必须按头部字段报**，并且校验只能落在 unpack
  // 这一层（唯一入口）。
  //
  // 域就是两个量化函数的像与库的域的交集：
  // - `c_q = quantize_param(c)`，而 `robust_soliton_checked` 要求 `c > 0`
  //   → `c_q ∈ [1, 255]`（0 即 c=0，被库拒绝）；
  // - `delta_q = quantize_param(delta)`，要求 `0 < delta <= 1`
  //   → `delta_q ∈ [1, 100]`（101 = 1.01 已超出上界）。
  //
  // 校验放在这里还有一个副作用（好的那种）：`decode_full` 此后不会再因为
  // **头部取值**而 raise `DistributionNotNormalized`，那个变体恢复成它本来的
  // 含义（调用方自己构造的分布表没归一化）。
  let c_q = r.byte()
  if c_q < 1 {
    raise LtError::InvalidHeaderField("c_q", c_q.to_uint64(), 1UL, 255UL)
  }
  let delta_q = r.byte()
  if delta_q < 1 || delta_q > 100 {
    raise LtError::InvalidHeaderField(
      "delta_q",
      delta_q.to_uint64(),
      1UL,
      100UL,
    )
  }
  let c = dequantize_param(c_q)
  let delta = dequantize_param(delta_q)
  // K 按无符号原值读出：后面的两个上界要用它做乘法，而它在 Int32 里可能
  // 是负数（`0x80000000`），负负相乘会把上界算成天文数字从而**放行**本该
  // 拒绝的 payload_len。
  let k_raw = r.u32_unsigned()
  // K 自身的域校验（LT-G，2026-11-10 审计）。
  //
  // 修复前 `K = 0x80000000` 变负后一路走到 `decoder.mbt` 的 `if k < 1`，
  // CLI 于是输出
  //
  //   ltcode: decode error: empty source: at least one source symbol with a
  //           non-zero length is required
  //
  // —— 把一个**头部字段非法**说成「输入为空」。用户据此会去检查自己的源
  // 文件，而那个文件根本没参与这次解码（decode 只读容器）。
  //
  // 上界的两个方向也一并收归这里：`K = 0` 同样误导（同一个空输入文案），
  // `K > max_source_symbols()` 会走 `SourceTooLarge`，文案读起来像
  // 「**你**给的源太大」，而实际是文件头部声明的 K 越界。三者对调用方的
  // 动作指引完全一样：这个文件不该被本构建读。
  let k_max = max_source_symbols().to_uint64()
  if k_raw < 1UL || k_raw > k_max {
    raise LtError::InvalidHeaderField("K", k_raw, 1UL, k_max)
  }
  let k = k_raw.to_int()
  let seed = r.u64()
  // symbol_len：按无符号读，域校验只用字段自身的取值范围（LT-I，
  // 2026-11-11 审计）。
  //
  // 修复前上界取的是「文件总长」：
  //
  // ```moonbit nocheck
  // let symbol_len_max = data.length().to_uint64()   // count=0 时恒为 43
  // ```
  //
  // 这条约束本意是「一个符号体不可能比整个文件还长」，但它只对**带符号体**
  // 的文件成立。`--count 0` 写出的零符号容器只有 43 字节头部，于是上界退化成
  // 「`symbol_len <= 43`」，把 `ceil(payload/K) > 43` 的合法头部全部判死
  // —— 对 README 用的 4000 字节 payload 就是 **K <= 93**。编码端与解码端对
  // 「同一个文件是否合法」给出相反答案，而 README 的 `--count 0` 例子恰好
  // 落在被拒的一侧（K=10 → symbol_len=400）：文档承诺 INCOMPLETE/exit 1，
  // 实际 exit 3「not a ltcode container」。
  //
  // 正确的域只由**字段自身**决定：`1 <= symbol_len <= Int32.MAX`。
  //
  // 为什么「不超过文件长度」这条不该留：它想防的是「一个符号体比整个文件还
  // 长」，而真正需要防的**分配**由下面的 `count_max` 负责 —— 每个符号占
  // `4 + symbol_len` 字节，`count_max = 剩余字节 / body_len` 一旦取 0，
  // 任何 `count >= 1` 都会报 `TruncatedSymbol`。`count == 0` 时一个符号体
  // 都不读，`peel` 的 `acc` 也只在收到符号时按 `symbol_len` 分配（`n == 0`
  // → 一次都不分配），因此不存在「头部声明了巨长的符号体就炸内存」的路径。
  // 反过来，`payload_len == 0` 这种格式允许、但 `from_bytes` 不会产出的
  // 头部（`header_guard_test.mbt` 已锁定）本来就要求 `symbol_len >= 1` 与
  // `payload_len` 无关。
  //
  // 两个方向的域校验都保留：`0` 和 `0x80000000`（会转成负数）仍然拒绝 ——
  // 放宽上界不等于取消域。
  let symbol_len_raw = r.u32_unsigned()
  let payload_len = r.u64()
  let int32_max_u = 2147483647UL
  if symbol_len_raw < 1UL || symbol_len_raw > int32_max_u {
    raise LtError::InvalidHeaderField(
      "symbol_len", symbol_len_raw, 1UL, int32_max_u,
    )
  }
  let symbol_len = symbol_len_raw.to_int()
  // payload_len：u64。合法上界受两个约束——`K × symbol_len`（`from_bytes`
  // 切块后的最大长度），以及 `Int32` 正数上限（`reassemble` 与
  // `Container.payload_len` 都用有符号 Int32，超出必须报错而不是截断）。
  let mut payload_len_max = k_raw * symbol_len_raw
  let int32_max = 2147483647UL
  if payload_len_max > int32_max {
    payload_len_max = int32_max
  }
  if payload_len > payload_len_max {
    raise LtError::InvalidHeaderField(
      "payload_len", payload_len, 0UL, payload_len_max,
    )
  }
  let payload_hash = r.u64()
  // count：u32，**分两层**判，因为"头部字段离谱"与"文件被截断"在头部上
  // 是不可区分的（都表现为「剩余字节装不下 count 个符号」），而两者对调用方
  // 的动作指引不同：
  //
  // 1. `count_raw > Int32 上限`：这个值转成 Int32 会变负，而
  //    `for i = 0; i < count` 对负数一次都不执行 —— 符号被**静默丢弃**，
  //    解码于是报 `INCOMPLETE`。这是 LT-A 的直接症状，必须报头部字段非法。
  // 2. `count_raw > count_max` 但仍在 Int32 正数范围内：只可能是文件被截断
  //    （或者 count 被改小/改大这种手工拼接）。报 `TruncatedSymbol`，
  //    措辞与真正的"读到一半没字节了"一致，调用方知道该重传。
  //
  // 上限本身：每个符号占 `4 + symbol_len` 字节（index + body），符号体在
  // 文档化的头部契约里是定长的，因此这个除法是精确的，不是估计。
  let count_raw = r.u32_unsigned()
  let int32_max_u = 2147483647UL
  let body_len = 4UL + symbol_len_raw
  let remaining = data.length().to_uint64() - header_len().to_uint64()
  let count_max = remaining / body_len
  if count_raw > int32_max_u {
    raise LtError::InvalidHeaderField("count", count_raw, 0UL, count_max)
  }
  if count_raw > count_max {
    // 报「够读几个符号 / 头部说要几个」而不是把两个字节数硬凑成同一量纲：
    // 这里说的就是符号个数，用户不需要自己再做一次除法。
    raise LtError::TruncatedSymbol(count_max.to_int(), count_raw.to_int())
  }
  let count = count_raw.to_int()
  let symbols : Array[ReceivedSymbol] = []
  for i = 0; i < count; i = i + 1 {
    let index = r.u32()
    let body = r.bytes(symbol_len)
    symbols.push(ReceivedSymbol::{ index, data: body, })
  }
  // 尾部校验（LT-D，2026-11-10 审计）：读完 count 个符号后必须**恰好**
  // 用完文件。
  //
  // 修复前这里什么都不查，于是三种「这不是同一份文件」全都 exit 0 并打印
  // 「checksum verified」：
  //
  //   cat good.ltc; printf JUNK... >> junk.ltc   → exit 0
  //   cat good.ltc good.ltc > double.ltc         → exit 0
  //   把 count 从 300 改成 2                     → exit 0
  //
  // 第三种是 `payload_hash` **明确抓不住**的一类：剩下的符号是完好的，
  // 而哈希是对解出来的 payload 算的。README 里「能抓住拼接错误」那句话
  // 因此在修复前不成立，已同步改写成如实描述。
  //
  // 与 `TruncatedSymbol` 是**两个方向**：截断是「读不到」，尾部多余是
  // 「读完了还剩」。混进同一个变体会让调用方分不清该重传还是该丢弃。
  let consumed = r.pos
  if consumed != data.length() {
    raise LtError::TrailingBytes(
      consumed.to_uint64(),
      data.length().to_uint64(),
    )
  }
  {
    k,
    seed,
    symbol_len,
    payload_len: payload_len.to_int(),
    payload_hash,
    c,
    delta,
    symbols,
  }
}

///|
/// **带上校验和的解码**：`Complete` 的含义里包含"哈希已核对通过"。
///
/// 为什么把它放在 `container.mbt` 而不是 CLI 里：这是**格式层**的责任。
/// 校验和是容器头的一部分，判断"解出来的东西对不对"需要它能重算哈希；
/// 让每个调用方（CLI、测试、未来的库用户）各自记得去比对，迟早有人漏掉
/// 一次，然后写出一份内容错误的文件。所以把它做成唯一入口。
///
/// 失败语义：
/// - 数据不足 → `Incomplete(..)`（正常返回值，不是错误）
/// - 解出来了但哈希不符 → `raise CorruptionDetected`（**不**返回 Complete）
///
/// 后者必须 raise 而不是返回 `Incomplete` —— 它跟"数据不够"是两件事。
/// 数据不够再要几个符号就行；哈希不符说明数据本身是坏的，再要也没用。
pub fn decode_verified(container : Container) -> DecodeResult raise LtError {
  let result = decode_full(
    container.seed,
    container.k,
    container.symbol_len,
    container.symbols,
    container.c,
    container.delta,
  )
  match result {
    Incomplete(_, _) => result
    Complete(sources) => {
      let bytes = reassemble(sources, container.payload_len)
      let actual = payload_hash(bytes)
      if actual != container.payload_hash {
        raise LtError::CorruptionDetected(actual, container.payload_hash)
      }
      result
    }
  }
}
