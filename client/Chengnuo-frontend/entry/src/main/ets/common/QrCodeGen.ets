/**
 * 二维码生成：Byte 模式 + 纠错 M 级 + 版本 1-40 自动选择。
 * 算法移植自 Kazuhiko Arase 的 qrcode-generator（MIT License，http://www.d-project.com/），
 * 输出矩阵与原实现逐位一致；仅支持 ASCII/Latin-1 文本，超出返回 null。
 */

const QR_G15: number = 0x537;
const QR_G18: number = 0x1F25;
const QR_G15_MASK: number = 0x5412;

const QR_PATTERN_POSITION_TABLE: number[][] = [
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
  [6, 30, 54],
  [6, 32, 58],
  [6, 34, 62],
  [6, 26, 46, 66],
  [6, 26, 48, 70],
  [6, 26, 50, 74],
  [6, 30, 54, 78],
  [6, 30, 56, 82],
  [6, 30, 58, 86],
  [6, 34, 62, 90],
  [6, 28, 50, 72, 94],
  [6, 26, 50, 74, 98],
  [6, 30, 54, 78, 102],
  [6, 28, 54, 80, 106],
  [6, 32, 58, 84, 110],
  [6, 30, 58, 86, 114],
  [6, 34, 62, 90, 118],
  [6, 26, 50, 74, 98, 122],
  [6, 30, 54, 78, 102, 126],
  [6, 26, 52, 78, 104, 130],
  [6, 30, 56, 82, 108, 134],
  [6, 34, 60, 86, 112, 138],
  [6, 30, 58, 86, 114, 142],
  [6, 34, 62, 90, 118, 146],
  [6, 30, 54, 78, 102, 126, 150],
  [6, 24, 50, 76, 102, 128, 154],
  [6, 28, 54, 80, 106, 132, 158],
  [6, 32, 58, 84, 110, 136, 162],
  [6, 26, 54, 82, 110, 138, 166],
  [6, 30, 58, 86, 114, 142, 170]
];

const QR_RS_BLOCKS_M: number[][] = [
  [1, 26, 16],
  [1, 44, 28],
  [1, 70, 44],
  [2, 50, 32],
  [2, 67, 43],
  [4, 43, 27],
  [4, 49, 31],
  [2, 60, 38, 2, 61, 39],
  [3, 58, 36, 2, 59, 37],
  [4, 69, 43, 1, 70, 44],
  [1, 80, 50, 4, 81, 51],
  [6, 58, 36, 2, 59, 37],
  [8, 59, 37, 1, 60, 38],
  [4, 64, 40, 5, 65, 41],
  [5, 65, 41, 5, 66, 42],
  [7, 73, 45, 3, 74, 46],
  [10, 74, 46, 1, 75, 47],
  [9, 69, 43, 4, 70, 44],
  [3, 70, 44, 11, 71, 45],
  [3, 67, 41, 13, 68, 42],
  [17, 68, 42],
  [17, 74, 46],
  [4, 75, 47, 14, 76, 48],
  [6, 73, 45, 14, 74, 46],
  [8, 75, 47, 13, 76, 48],
  [19, 74, 46, 4, 75, 47],
  [22, 73, 45, 3, 74, 46],
  [3, 73, 45, 23, 74, 46],
  [21, 73, 45, 7, 74, 46],
  [19, 75, 47, 10, 76, 48],
  [2, 74, 46, 29, 75, 47],
  [10, 74, 46, 23, 75, 47],
  [14, 74, 46, 21, 75, 47],
  [14, 74, 46, 23, 75, 47],
  [12, 75, 47, 26, 76, 48],
  [6, 75, 47, 34, 76, 48],
  [29, 74, 46, 14, 75, 47],
  [13, 74, 46, 32, 75, 47],
  [40, 75, 47, 7, 76, 48],
  [18, 75, 47, 31, 76, 48]
];

class QrGfTables {
  readonly exp: number[] = [];
  readonly log: number[] = [];

  constructor() {
    for (let i = 0; i < 8; i++) {
      this.exp.push(1 << i);
    }
    for (let i = 8; i < 256; i++) {
      this.exp.push(this.exp[i - 4] ^ this.exp[i - 5] ^ this.exp[i - 6] ^ this.exp[i - 8]);
    }
    for (let i = 0; i < 256; i++) {
      this.log.push(0);
    }
    for (let i = 0; i < 255; i++) {
      this.log[this.exp[i]] = i;
    }
  }
}

class QrMath {
  private static tables: QrGfTables | null = null;

  private static ensure(): QrGfTables {
    if (QrMath.tables === null) {
      QrMath.tables = new QrGfTables();
    }
    return QrMath.tables;
  }

  static glog(n: number): number {
    if (n < 1) {
      return 0;
    }
    return QrMath.ensure().log[n];
  }

  static gexp(n: number): number {
    let v = n;
    while (v < 0) {
      v += 255;
    }
    while (v >= 256) {
      v -= 255;
    }
    return QrMath.ensure().exp[v];
  }
}

class QrBitBuffer {
  private buffer: number[] = [];
  private length: number = 0;

  getLengthInBits(): number {
    return this.length;
  }

  put(num: number, len: number): void {
    for (let i = 0; i < len; i++) {
      this.putBit(((num >>> (len - i - 1)) & 1) === 1);
    }
  }

  putBit(bit: boolean): void {
    const bufIndex = Math.floor(this.length / 8);
    if (this.buffer.length <= bufIndex) {
      this.buffer.push(0);
    }
    if (bit) {
      this.buffer[bufIndex] |= 0x80 >>> (this.length % 8);
    }
    this.length++;
  }

  getByte(index: number): number {
    return this.buffer[index];
  }
}

class QrPolynomial {
  private readonly coefs: number[];

  constructor(coefs: number[], shift: number) {
    let offset = 0;
    while (offset < coefs.length && coefs[offset] === 0) {
      offset++;
    }
    this.coefs = [];
    const total = coefs.length - offset + shift;
    for (let i = 0; i < total; i++) {
      this.coefs.push(0);
    }
    for (let i = 0; i < coefs.length - offset; i++) {
      this.coefs[i] = coefs[offset + i];
    }
  }

  getAt(index: number): number {
    return this.coefs[index];
  }

  getLength(): number {
    return this.coefs.length;
  }

  multiply(e: QrPolynomial): QrPolynomial {
    const num: number[] = [];
    const total = this.getLength() + e.getLength() - 1;
    for (let i = 0; i < total; i++) {
      num.push(0);
    }
    for (let i = 0; i < this.getLength(); i++) {
      for (let j = 0; j < e.getLength(); j++) {
        num[i + j] ^= QrMath.gexp(QrMath.glog(this.getAt(i)) + QrMath.glog(e.getAt(j)));
      }
    }
    return new QrPolynomial(num, 0);
  }

  mod(e: QrPolynomial): QrPolynomial {
    if (this.getLength() - e.getLength() < 0) {
      return this;
    }
    const ratio = QrMath.glog(this.getAt(0)) - QrMath.glog(e.getAt(0));
    const num: number[] = [];
    for (let i = 0; i < this.getLength(); i++) {
      num.push(this.getAt(i));
    }
    for (let i = 0; i < e.getLength(); i++) {
      num[i] ^= QrMath.gexp(QrMath.glog(e.getAt(i)) + ratio);
    }
    return new QrPolynomial(num, 0).mod(e);
  }
}

class QrRsBlock {
  readonly totalCount: number;
  readonly dataCount: number;

  constructor(totalCount: number, dataCount: number) {
    this.totalCount = totalCount;
    this.dataCount = dataCount;
  }
}

function getRsBlocksM(version: number): QrRsBlock[] {
  const table: number[] = QR_RS_BLOCKS_M[version - 1];
  const list: QrRsBlock[] = [];
  for (let i = 0; i + 2 < table.length; i += 3) {
    const count = table[i];
    const totalCount = table[i + 1];
    const dataCount = table[i + 2];
    for (let j = 0; j < count; j++) {
      list.push(new QrRsBlock(totalCount, dataCount));
    }
  }
  return list;
}

function getErrorCorrectPolynomial(errorCorrectLength: number): QrPolynomial {
  let poly = new QrPolynomial([1], 0);
  for (let i = 0; i < errorCorrectLength; i++) {
    poly = poly.multiply(new QrPolynomial([1, QrMath.gexp(i)], 0));
  }
  return poly;
}

function getBCHDigit(data: number): number {
  let digit = 0;
  let d = data;
  while (d !== 0) {
    digit++;
    d = d >>> 1;
  }
  return digit;
}

function getBCHTypeInfo(data: number): number {
  let d = data << 10;
  while (getBCHDigit(d) - getBCHDigit(QR_G15) >= 0) {
    d ^= QR_G15 << (getBCHDigit(d) - getBCHDigit(QR_G15));
  }
  return ((data << 10) | d) ^ QR_G15_MASK;
}

function getBCHTypeNumber(data: number): number {
  let d = data << 12;
  while (getBCHDigit(d) - getBCHDigit(QR_G18) >= 0) {
    d ^= QR_G18 << (getBCHDigit(d) - getBCHDigit(QR_G18));
  }
  return (data << 12) | d;
}

function getMask(maskPattern: number, i: number, j: number): boolean {
  switch (maskPattern) {
    case 0:
      return (i + j) % 2 === 0;
    case 1:
      return i % 2 === 0;
    case 2:
      return j % 3 === 0;
    case 3:
      return (i + j) % 3 === 0;
    case 4:
      return (Math.floor(i / 2) + Math.floor(j / 3)) % 2 === 0;
    case 5:
      return (i * j) % 2 + (i * j) % 3 === 0;
    case 6:
      return ((i * j) % 2 + (i * j) % 3) % 2 === 0;
    case 7:
      return ((i * j) % 3 + (i + j) % 2) % 2 === 0;
    default:
      return false;
  }
}

function createCodewords(version: number, text: string): number[] {
  const rsBlocks = getRsBlocksM(version);
  let totalDataCount = 0;
  for (let i = 0; i < rsBlocks.length; i++) {
    totalDataCount += rsBlocks[i].dataCount;
  }
  const buffer = new QrBitBuffer();
  buffer.put(4, 4);
  buffer.put(text.length, version < 10 ? 8 : 16);
  for (let i = 0; i < text.length; i++) {
    buffer.put(text.charCodeAt(i), 8);
  }
  if (buffer.getLengthInBits() + 4 <= totalDataCount * 8) {
    buffer.put(0, 4);
  }
  while (buffer.getLengthInBits() % 8 !== 0) {
    buffer.putBit(false);
  }
  while (buffer.getLengthInBits() < totalDataCount * 8) {
    buffer.put(0xEC, 8);
    if (buffer.getLengthInBits() < totalDataCount * 8) {
      buffer.put(0x11, 8);
    }
  }
  return interleaveBytes(buffer, rsBlocks);
}

function interleaveBytes(buffer: QrBitBuffer, rsBlocks: QrRsBlock[]): number[] {
  let offset = 0;
  let maxDcCount = 0;
  let maxEcCount = 0;
  const dcdata: number[][] = [];
  const ecdata: number[][] = [];

  for (let r = 0; r < rsBlocks.length; r++) {
    const dcCount = rsBlocks[r].dataCount;
    const ecCount = rsBlocks[r].totalCount - dcCount;
    if (dcCount > maxDcCount) {
      maxDcCount = dcCount;
    }
    if (ecCount > maxEcCount) {
      maxEcCount = ecCount;
    }
    const dc: number[] = [];
    for (let i = 0; i < dcCount; i++) {
      dc.push(0xFF & buffer.getByte(i + offset));
    }
    offset += dcCount;
    dcdata.push(dc);

    const rsPoly = getErrorCorrectPolynomial(ecCount);
    const rawPoly = new QrPolynomial(dc, rsPoly.getLength() - 1);
    const modPoly = rawPoly.mod(rsPoly);
    const ec: number[] = [];
    for (let i = 0; i < rsPoly.getLength() - 1; i++) {
      ec.push(0);
    }
    for (let i = 0; i < ec.length; i++) {
      const modIndex = i + modPoly.getLength() - ec.length;
      if (modIndex >= 0) {
        ec[i] = modPoly.getAt(modIndex);
      }
    }
    ecdata.push(ec);
  }

  const data: number[] = [];
  for (let i = 0; i < maxDcCount; i++) {
    for (let r = 0; r < rsBlocks.length; r++) {
      if (i < dcdata[r].length) {
        data.push(dcdata[r][i]);
      }
    }
  }
  for (let i = 0; i < maxEcCount; i++) {
    for (let r = 0; r < rsBlocks.length; r++) {
      if (i < ecdata[r].length) {
        data.push(ecdata[r][i]);
      }
    }
  }
  return data;
}

export class QrMatrix {
  readonly moduleCount: number;
  private readonly modules: boolean[][];

  constructor(moduleCount: number, modules: boolean[][]) {
    this.moduleCount = moduleCount;
    this.modules = modules;
  }

  isDark(row: number, col: number): boolean {
    if (row < 0 || this.moduleCount <= row || col < 0 || this.moduleCount <= col) {
      return false;
    }
    return this.modules[row][col];
  }
}

class QrBuilder {
  private readonly version: number;
  private readonly moduleCount: number;
  private readonly codewords: number[];
  private modules: (boolean | null)[][] = [];

  constructor(version: number, codewords: number[]) {
    this.version = version;
    this.moduleCount = version * 4 + 17;
    this.codewords = codewords;
  }

  build(): QrMatrix {
    let bestMask = 0;
    let bestLost = 0;
    for (let mask = 0; mask < 8; mask++) {
      this.setupModules(mask, true);
      const lost = this.getLostPoint();
      if (mask === 0 || bestLost > lost) {
        bestLost = lost;
        bestMask = mask;
      }
    }
    this.setupModules(bestMask, false);
    const flat: boolean[][] = [];
    for (let r = 0; r < this.moduleCount; r++) {
      const row: boolean[] = [];
      for (let c = 0; c < this.moduleCount; c++) {
        row.push(this.modules[r][c] === true);
      }
      flat.push(row);
    }
    return new QrMatrix(this.moduleCount, flat);
  }

  private setupModules(mask: number, test: boolean): void {
    this.modules = [];
    for (let r = 0; r < this.moduleCount; r++) {
      const row: (boolean | null)[] = [];
      for (let c = 0; c < this.moduleCount; c++) {
        row.push(null);
      }
      this.modules.push(row);
    }
    this.setupPositionProbePattern(0, 0);
    this.setupPositionProbePattern(this.moduleCount - 7, 0);
    this.setupPositionProbePattern(0, this.moduleCount - 7);
    this.setupPositionAdjustPattern();
    this.setupTimingPattern();
    this.setupTypeInfo(test, mask);
    if (this.version >= 7) {
      this.setupTypeNumber(test);
    }
    this.mapData(mask);
  }

  private setupPositionProbePattern(row: number, col: number): void {
    for (let r = -1; r <= 7; r++) {
      if (row + r <= -1 || this.moduleCount <= row + r) {
        continue;
      }
      for (let c = -1; c <= 7; c++) {
        if (col + c <= -1 || this.moduleCount <= col + c) {
          continue;
        }
        if ((0 <= r && r <= 6 && (c === 0 || c === 6))
          || (0 <= c && c <= 6 && (r === 0 || r === 6))
          || (2 <= r && r <= 4 && 2 <= c && c <= 4)) {
          this.modules[row + r][col + c] = true;
        } else {
          this.modules[row + r][col + c] = false;
        }
      }
    }
  }

  private setupPositionAdjustPattern(): void {
    const pos = QR_PATTERN_POSITION_TABLE[this.version - 1];
    for (let i = 0; i < pos.length; i++) {
      for (let j = 0; j < pos.length; j++) {
        const row = pos[i];
        const col = pos[j];
        if (this.modules[row][col] !== null) {
          continue;
        }
        for (let r = -2; r <= 2; r++) {
          for (let c = -2; c <= 2; c++) {
            if (r === -2 || r === 2 || c === -2 || c === 2 || (r === 0 && c === 0)) {
              this.modules[row + r][col + c] = true;
            } else {
              this.modules[row + r][col + c] = false;
            }
          }
        }
      }
    }
  }

  private setupTimingPattern(): void {
    for (let r = 8; r < this.moduleCount - 8; r++) {
      if (this.modules[r][6] !== null) {
        continue;
      }
      this.modules[r][6] = r % 2 === 0;
    }
    for (let c = 8; c < this.moduleCount - 8; c++) {
      if (this.modules[6][c] !== null) {
        continue;
      }
      this.modules[6][c] = c % 2 === 0;
    }
  }

  private setupTypeNumber(test: boolean): void {
    const bits = getBCHTypeNumber(this.version);
    for (let i = 0; i < 18; i++) {
      const mod = !test && ((bits >>> i) & 1) === 1;
      this.modules[Math.floor(i / 3)][(i % 3) + this.moduleCount - 8 - 3] = mod;
    }
    for (let i = 0; i < 18; i++) {
      const mod = !test && ((bits >>> i) & 1) === 1;
      this.modules[(i % 3) + this.moduleCount - 8 - 3][Math.floor(i / 3)] = mod;
    }
  }

  private setupTypeInfo(test: boolean, mask: number): void {
    const data = mask;
    const bits = getBCHTypeInfo(data);
    for (let i = 0; i < 15; i++) {
      const mod = !test && ((bits >>> i) & 1) === 1;
      if (i < 6) {
        this.modules[i][8] = mod;
      } else if (i < 8) {
        this.modules[i + 1][8] = mod;
      } else {
        this.modules[this.moduleCount - 15 + i][8] = mod;
      }
    }
    for (let i = 0; i < 15; i++) {
      const mod = !test && ((bits >>> i) & 1) === 1;
      if (i < 8) {
        this.modules[8][this.moduleCount - i - 1] = mod;
      } else if (i < 9) {
        this.modules[8][15 - i - 1 + 1] = mod;
      } else {
        this.modules[8][15 - i - 1] = mod;
      }
    }
    this.modules[this.moduleCount - 8][8] = !test;
  }

  private mapData(mask: number): void {
    let inc = -1;
    let row = this.moduleCount - 1;
    let bitIndex = 7;
    let byteIndex = 0;
    const data = this.codewords;
    for (let col = this.moduleCount - 1; col > 0; col -= 2) {
      if (col === 6) {
        col--;
      }
      let going = true;
      while (going) {
        for (let c = 0; c < 2; c++) {
          if (this.modules[row][col - c] === null) {
            let dark = false;
            if (byteIndex < data.length) {
              dark = ((data[byteIndex] >>> bitIndex) & 1) === 1;
            }
            if (getMask(mask, row, col - c)) {
              dark = !dark;
            }
            this.modules[row][col - c] = dark;
            bitIndex--;
            if (bitIndex === -1) {
              byteIndex++;
              bitIndex = 7;
            }
          }
        }
        row += inc;
        if (row < 0 || this.moduleCount <= row) {
          row -= inc;
          inc = -inc;
          going = false;
        }
      }
    }
  }

  private getLostPoint(): number {
    const mc = this.moduleCount;
    let lostPoint = 0;
    for (let row = 0; row < mc; row++) {
      for (let col = 0; col < mc; col++) {
        let sameCount = 0;
        const dark = this.modules[row][col] === true;
        for (let r = -1; r <= 1; r++) {
          if (row + r < 0 || mc <= row + r) {
            continue;
          }
          for (let c = -1; c <= 1; c++) {
            if (col + c < 0 || mc <= col + c) {
              continue;
            }
            if (r === 0 && c === 0) {
              continue;
            }
            if (dark === (this.modules[row + r][col + c] === true)) {
              sameCount++;
            }
          }
        }
        if (sameCount > 5) {
          lostPoint += 3 + sameCount - 5;
        }
      }
    }
    for (let row = 0; row < mc - 1; row++) {
      for (let col = 0; col < mc - 1; col++) {
        let count = 0;
        if (this.modules[row][col] === true) {
          count++;
        }
        if (this.modules[row + 1][col] === true) {
          count++;
        }
        if (this.modules[row][col + 1] === true) {
          count++;
        }
        if (this.modules[row + 1][col + 1] === true) {
          count++;
        }
        if (count === 0 || count === 4) {
          lostPoint += 3;
        }
      }
    }
    for (let row = 0; row < mc; row++) {
      for (let col = 0; col < mc - 6; col++) {
        if (this.modules[row][col] === true
          && this.modules[row][col + 1] !== true
          && this.modules[row][col + 2] === true
          && this.modules[row][col + 3] === true
          && this.modules[row][col + 4] === true
          && this.modules[row][col + 5] !== true
          && this.modules[row][col + 6] === true) {
          lostPoint += 40;
        }
      }
    }
    for (let col = 0; col < mc; col++) {
      for (let row = 0; row < mc - 6; row++) {
        if (this.modules[row][col] === true
          && this.modules[row + 1][col] !== true
          && this.modules[row + 2][col] === true
          && this.modules[row + 3][col] === true
          && this.modules[row + 4][col] === true
          && this.modules[row + 5][col] !== true
          && this.modules[row + 6][col] === true) {
          lostPoint += 40;
        }
      }
    }
    let darkCount = 0;
    for (let col = 0; col < mc; col++) {
      for (let row = 0; row < mc; row++) {
        if (this.modules[row][col] === true) {
          darkCount++;
        }
      }
    }
    const ratio = Math.abs(100 * darkCount / mc / mc - 50) / 5;
    lostPoint += ratio * 10;
    return lostPoint;
  }
}

export class QrCodeGen {
  static encode(text: string): QrMatrix | null {
    for (let i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) > 0xFF) {
        return null;
      }
    }
    for (let version = 1; version <= 40; version++) {
      const rsBlocks = getRsBlocksM(version);
      let totalDataCount = 0;
      for (let i = 0; i < rsBlocks.length; i++) {
        totalDataCount += rsBlocks[i].dataCount;
      }
      const bits = 4 + (version < 10 ? 8 : 16) + text.length * 8;
      if (bits <= totalDataCount * 8) {
        const codewords = createCodewords(version, text);
        return new QrBuilder(version, codewords).build();
      }
    }
    return null;
  }
}
