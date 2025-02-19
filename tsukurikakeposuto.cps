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
    const [x, y, z, f] = args;
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
    writeln(leadOutMovement);
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
        if (pendingRadiusCompensation >= 0) {
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
}

var onSectionEnd = () => {
    cuttingZones.forEach(cz => writeln(JSON.stringify(cz)));
    
    if (cuttingZones.length === 0) {
        cuttingZones.push(CLs);
    }

    for (const cz of cuttingZones) {
        ProcessZone(cz);
        cz.forEach(zone => writeln(JSON.stringify(zone)));
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