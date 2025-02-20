certificationLevel = 2;
description = "TSUKURIKAKE_POSUTO";

extension = "nc";
setCodePage("utf-8");
capabilities = CAPABILITY_MILLING;

allowedCircularPlanes = 1 << PLANE_XY; // set 001b by bit-shift

const gFormat = createFormat({ prefix: "G", decimals: 0, zeropad: true, width: 2 });
const mFormat = createFormat({ prefix: "M", decimals: 0, zeropad: true, width: 2 });

const xyzFormat = createFormat({ decimals: 3, forceDecimal: true });
const feedFormat = createFormat({ decimals: 3, forceDecimal: true });

const xOutput = createOutputVariable({ prefix: "X" }, xyzFormat);
const yOutput = createOutputVariable({ prefix: "Y" }, xyzFormat);
const iOutput = createOutputVariable({ prefix: "I" }, xyzFormat);
const jOutput = createOutputVariable({ prefix: "J" }, xyzFormat);
const feedOutput = createOutputVariable({ prefix: "F" }, feedFormat);

let gMotionModal;
let pendingRadiusCompensation = -1;
let globalIndex = 1;
let initPos = {};

const RAPID = 0;
const LINEAR = 1;
const CIRCULAR = 2;

let CLs = [];
let cuttingZones = [];

const writeBlock = (...args) => {
    writeWords(args);
}

const forceMotion = () => {
    xOutput.reset();
    yOutput.reset();
    iOutput.reset();
    jOutput.reset();
    gMotionModal.reset();
}

const forceAny = () => {
    forceMotion();
    feedOutput.reset();
}

const GetCL = args => {
    const start = getCurrentPosition();
    return {movement, args, start};
}

const GetFeed = f => {
    return f ? feedFormat.format(f) : "";
}


var onLinear  = (...args) => {
    const [x, y, z, f] = args; //分割代入しているだけ
    const CL = GetCL({ x, y, z, f });
    CL.type = LINEAR;
    CLs.push(CL); // ツールパスに対応するEntryFunctionがInvokeされたときに引数をもとに宣言したCLをCLsに積み上げる
}

var onCircular = (...args) => {
    const [clockwise, cx, cy, cz, x, y, z, f] = args;
    const CL = GetCL({ clockwise, cx, cy, cz, x, y, z, f, isfullCircle: isFullCircle() });
    CL.type = CIRCULAR;
    CLs.push(CL);
}

var onRadiusCompensation = () => {
    CLs.push({ radiusCompensation });
}

leadOutMovement = undefined;
var onMovement = () => {
    if (leadOutMovement) {
        cuttingZones.push(CLs);
        CLs = [];
        leadOutMovement = undefined;
    }

    if (movement === MOVEMENT_LEAD_OUT) {
        leadOutMovement = true;
    }
}


const ProcessLinear = CL => {
    if (pendingRadiusCompensation >= 0) {
        forceMotion();
    }

    const x = xOutput.format(CL.args.x);
    const y = yOutput.format(CL.args.y);
    const f = GetFeed(CL.args.feed);

    if (x || y) {
        if (pendingRadiusCompensation >= 0) { //径補正が保留中であれば補正を処理した上で保留を解除する
            switch (pendingRadiusCompensation) {
                case RADIUS_COMPENSATION_LEFT:
                    writeBlock(gFormat.format(41), x, y, f);
                    break;
                case RADIUS_COMPENSATION_RIGHT:
                    writeBlock(gFormat.format(42), x, y, f);
                    break;
                default:
                    writeBlock(gFormat.format(40), x, y, f);
            }
            pendingRadiusCompensation = -1;
        }
        else {
            writeBlock(gFormat.format(1), x, y, f);
        }
    }
}

const ProcessCircular = CL => {
    if (pendingRadiusCompensation >= 0) {
        writeln("エラー: 径補正モードの変更は直線動作時に行う必要があります");
        return;
    }

    if (CL.isFullCircle) {
        writeln("エラー: 円弧の動作は360°未満にする必要があります");
        return;
    }

    forceMotion();
    const x = xOutput.format(CL.args.x);
    const y = yOutput.format(CL.args.y);
    const i = iOutput.format(CL.args.cx - CL.start.x);
    const j = jOutput.format(CL.args.cy - CL.start.y);
    const f = GetFeed(CL.args.feed);
    writeBlock(gFormat.format(CL.args.clockwise ? 2 : 3), x, y, i, j, f);
}

const ProcessCuttingLine = CL => {
    if (CL === undefined) {
        writeln("undefined");
        return;
    }

    if (CL.radiusCompensation !== undefined) {
        if (pendingRadiusCompensation === -1) {
            pendingRadiusCompensation = CL.radiusCompensation;
        }
        else {
            writeln("エラー: 径補正の保留中に新たに径補正が発生しました");
        }
    }
    
    switch (CL.type) {
        case LINEAR:
            ProcessLinear(CL);
            break;
        case CIRCULAR:
            ProcessCircular(CL);
            break;
    }
}

const Preparing = CL => {
    initPos.x = xOutput.format(CL.args.x);
    initPos.y = yOutput.format(CL.args.y);

    if (globalIndex > 1) {
        writeBlock(gFormat.format(1), initPos.x, initPos.y, feedOutput.format(800.));
    }

    writeln("(Zone: " + globalIndex + ")");
    writeBlock(mFormat.format(78));
    writeBlock(mFormat.format(78));
    writeBlock(mFormat.format(80));
    writeBlock(mFormat.format(82));
    writeBlock(mFormat.format(84));
    writeBlock(gFormat.format(90));
    writeBlock(gFormat.format(92), initPos.x, initPos.y);
    writeBlock(mFormat.format(90));
    forceAny();
}

const PartingOff = CL => {
    writeBlock(mFormat.format(1));

    CL.args.f = 0; //切り落としをツールパスとして出力させるために工具設定でF0.1にしている 0.1をそのまま出さないために上書き
    ProcessCuttingLine(CL);

    writeBlock(mFormat.format(91));
    writeBlock(gFormat.format(0));

    forceAny();
    writeBlock(gFormat.format(40), initPos.x, initPos.y, feedOutput.format(500.));
}

const ProcessZone = cz => {
    const runUp = cz.filter(zone => zone.movement === MOVEMENT_LINK_TRANSITION || zone.movement === MOVEMENT_CUTTING || zone.movement === MOVEMENT_LEAD_IN);
    const cutting = cz.filter(zone => zone.movement === MOVEMENT_FINISH_CUTTING || zone.radiusCompensation !== undefined);
    const leadOut = cz.filter(zone => zone.movement === MOVEMENT_LEAD_OUT);

    pendingRadiusCompensation = -1;
    Preparing(runUp[runUp.length - 1]);
    for (const CL of cutting) {
        ProcessCuttingLine(CL);
    }
    pendingRadiusCompensation = -1;
    PartingOff(leadOut[0]);
}


var onOpen = () => {
    if (getProperty("separateWordWithSpace"), true) setWordSeparator(" ");
    else setWordSeparator("");

    if (getProperty("useGModal"), false) gMotionModal = createModal(gFormat);
    else gMotionModal = createModal({ force: true }, gFormat);

    writeln("%");
}

var onSection = () => {
    leadOutMovement = undefined;
    CLs = [];
    cuttingZones = [];
}

var onSectionEnd = () => {
    cuttingZones.forEach(cz => writeln(JSON.stringify(cz)));
    
    if (cuttingZones.length === 0) {
        cuttingZones.push(CLs);
    }

    for (const cz of cuttingZones) {
        ProcessZone(cz);
        globalIndex++;
    }
}

var onClose = () => {
    writeBlock(mFormat.format(2));
    writeln("%");

    GenerateMovementTypeList();
}

const sectionAmount = 2;

const PropertyGen = () => {
    const P = {
        separateWordWithSpace: {
            title: "ブロックをスペースで分けるか",
            group: "format",
            type: "boolean",
            value: true,
        },
        useGModal: {
            title: "Gコードをモーダルで出力するか",
            group: "format",
            type: "boolean",
            value: false,
            default: false
        }
    }

    for (let i = 0; i < sectionAmount; i++) {
        P[`section${i}`] = {
            group: `Section ${i}`,
            title: "doukana",
            type: "number",
            value: 0,
            default: 0
        }
    }

    return P;
}

properties = PropertyGen();

const GenerateMovementTypeList = () => {
    const movements = [
        "MOVEMENT_RAPID",
        "MOVEMENT_LEAD_IN",
        "MOVEMENT_CUTTING",
        "MOVEMENT_LEAD_OUT",
        "MOVEMENT_LINK_TRANSITION",
        "MOVEMENT_LINK_DIRECT",
        "MOVEMENT_RAMP_HELIX",
        "MOVEMENT_RAMP_PROFILE",
        "MOVEMENT_RAMP_ZIG_ZAG",
        "MOVEMENT_RAMP",
        "MOVEMENT_PLUNGE",
        "MOVEMENT_PREDRILL",
        "MOVEMENT_REDUCED",
        "MOVEMENT_FINISH_CUTTING",
        "MOVEMENT_HIGH_FEED"
    ];

    for (const m in movements) {
        writeln(movements[m] + ": " + m);
    }
}


/*
Fusionのポストにおける留意事項
 PostProcesserScriptで使用されるあまたのカスタム関数が存在する
  詳細はAutodeskのcam.autodesk.comを参照すること
 コピペによる移植性を持たせるために、直線移動のG01についてモーダルを利用せずに都度G01と出力する

Javascriptにおける留意事項
 Number型の特徴
  すべて浮動小数点で演算される
  →整数の演算結果が整数でないことがある
   解析的に処理する際には問題にならないが、比較を行うとき意図しない動作を起こしうる
 関数の定義方法
  ここでは原則アロー関数を用いる
   thisをレキシカルスコープで動作させるため　→　this一個も使わなかった！　インスタンス使わなかったからな…
   関数の巻き上げをエラーとして扱うため　→　エントリー関数はvar宣言じゃないとPostProcessorから怒られた
 UseStrictについて
  まだStrictモードは適用していない
   より正しいコードを書くことができるようになるが、
    グローバル変数の扱われ方が変わることでのポスト処理の影響が未検討であるため保留

このなぞスクコンフィグの注意点
 補正タイプ：制御機　進入→水平進入半径0、進入内角度0、直線進入距離0.02の、
  直線で進入するCuttingLineがFusionから渡されることを想定しています
  -> 進入動作は無視することにしました
 切り落とし動作を行いたい場合は、進入エンド距離に任意の切り落とし距離を設定した上で
  退出送り速度に切削送り速度と異なる値を設定してください
このなぞスクConfigのここがダメ
 しょっちゅう想定外の条件を握りつぶしている
  →ユーザー側の操作ミスなのか、ポストの仕様に誤りがあるのか判別がつけにくい
 想定（期待）しているCLの範囲が狭い　強く限定している
  にありーいこーる　デバッグ不足
 進入動作や退出動作を行っているCLをかなり強引にフラグを用いて握りつぶしている
  デバッグ用のコードをコメントアウトして残しているのでがんばること
  できればMillingではなくFabricationのCuttingを用いたかったが、仕方なし
*/
