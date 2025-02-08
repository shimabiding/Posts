certificationLevel = 2;

description = "ABIDING";

extension = "nc";
setCodePage("utf-8");
programNameIsInteger = true;
capabilities = CAPABILITY_MILLING;

minimumChordLength = spatial(0.25, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(2000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(319);
allowedCircularPlanes = 1 << PLANE_XY; // set 001b by bit-shift

const gFormat = createFormat({ prefix: "G", decimals: 0, zeropad: true, width: 2 });
const mFormat = createFormat({ prefix: "M", decimals: 0, zeropad: true, width: 2 });
const eFormat = createFormat({ prefix: "E", decimals: 0, zeropad: true, width: 4 });
const hFormat = createFormat({ prefix: "H", decimals: 0 });

const xyzFormat = createFormat({ decimals: 3, forceDecimal: true });
const feedFormat = createFormat({ decimals: 3, forceDecimal: true });

const xOutput = createOutputVariable({ prefix: "X" }, xyzFormat);
const yOutput = createOutputVariable({ prefix: "Y" }, xyzFormat);
const iOutput = createOutputVariable({ prefix: "I" }, xyzFormat);
const jOutput = createOutputVariable({ prefix: "J" }, xyzFormat);
const feedOutput = createOutputVariable({ prefix: "F" }, feedFormat);

let pendingRadiusCompensation = -1;

const RAPID = 0;
const LINEAR = 1;
const CIRCULAR = 2;

let CLs = [];
let initialPosition = undefined;
let firstInitialPosition = undefined;

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

const GetCL = (args) => {
    start = getCurrentPosition();
    return { movement, args, start};
}

const GetFeed = f => {
    return f ? feedOutput.format(f) : "";
}


var onRadiusCompensation = () => {
    CLs.push({ radiusCompensation });
}

var onLinear = (...args) => {
    const CL = GetCL({ x: args[0], y: args[1], z: args[2], feed: args[3] });
    CL.type = LINEAR;
    CLs.push(CL);
}

var onCircular = (...args) => {
    const CL = GetCL({clockwise: args[0], cx: args[1], cy: args[2], cz: args[3], x: args[4], y: args[5], z: args[6], feed: args[7]}, isFullCircle());
    CL.type = CIRCULAR;
    CLs.push(CL);
}

const Preparing = (x, y, f) => {
    if (!isFirstSection()) writeBlock(gFormat.format(1), x, y, feedOutput.format(500.));
    initialPosition = { x, y };

    writeln(`(Section ${currentSection.getId() + 1})`);

    writeBlock(mFormat.format(78));
    writeBlock(mFormat.format(78));
    writeBlock(mFormat.format(80));
    writeBlock(mFormat.format(82));
    writeBlock(mFormat.format(84));
    writeBlock(gFormat.format(90));
    writeBlock(gFormat.format(92), x, y);
    writeBlock(mFormat.format(90));
    forceAny();
}

const ProcessLinear = (CL) => {
    if (pendingRadiusCompensation >= 0) {
        xOutput.reset();
        yOutput.reset();
    }

    const x = xOutput.format(CL.args.x);
    const y = yOutput.format(CL.args.y);
    const f = GetFeed(CL.args.feed);

    if (CL.movement == MOVEMENT_LEAD_IN) {
        Preparing(x, y, f);
        return;
    }

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
        } else {
            writeBlock(gMotionModal.format(1), x, y, f);
        }
    }
}

const ProcessCircular = (CL) => {
    if (pendingRadiusCompensation >= 0) {
        //error("円弧動作時に径補正を行うことはできません。");
        writeln(`円弧動作時に径補正を行おうとしています`);
        return;
    }
    if (CL.isFullCircle) {
        error("円弧は360°未満にしてください。");
        return;
    }
    forceMotion();

    const x = xOutput.format(CL.args.x);
    const y = yOutput.format(CL.args.y);
    const i = iOutput.format(CL.args.cx - CL.start.x);
    const j = jOutput.format(CL.args.cy - CL.start.y);
    const f = GetFeed(CL.args.feed);
    writeBlock(gMotionModal.format(CL.args.clockwise ? 2 : 3), x, y, i, j, f);
}

const ProcessCuttingLine = (CL) => {
    if (CL.radiusCompensation != undefined) {
        if (pendingRadiusCompensation == -1) pendingRadiusCompensation = CL.radiusCompensation;
        else error(`径補正保留中に新たに径補正を設定することはできません。pendingRadiusCompensationValue:  ${pendingRadiusCompensation}}`);
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


var onOpen = () => {
    if (getProperty("separeteWordsWithSpace"), true) setWordSeparator(" ");
    else setWordSeparator("");

    if (getProperty("useGModal"), false) gMotionModal = createModal(gFormat);
    else gMotionModal = createModal({ force: true }, gFormat);

    writeln("%");

    let currentTool = getToolTable().getTool(0);
    //writeWords(currentTool.diameter ? `(wire diameter: ${currentTool.diameter})` : "");

    //writeln(capabilities.toString(2));
    // 上でビット演算を行い受け入れる加工タイプを限定している　そのビット演算結果の確認用Write
}

var onSection = () => {
    CLs = [];
    forceAny();

    initialPosition = currentSection.getInitialPosition();
    if (isFirstSection()) firstInitialPosition = initialPosition;
    forceMotion();
    //writeBlock(gFormat.format(92), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
}

var onSectionEnd = () => {
    //CLs.forEach(CL => { writeln(JSON.stringify(CL)) });

    let cuttingCLs = CLs.filter((CL) => CL.movement == MOVEMENT_LEAD_IN || CL.movement == MOVEMENT_FINISH_CUTTING || CL.movement == MOVEMENT_LEAD_OUT || CL.radiusCompensation != undefined);
    let leadInFinished = false;
    pendingRadiusCompensation = -1;
    for (let i = 0; i < cuttingCLs.length; i++) {
        if (cuttingCLs[i].movement == MOVEMENT_LEAD_OUT) break;
        //writeln(JSON.stringify(cuttingCLs[i]));
        ProcessCuttingLine(cuttingCLs[i]);
    }
    
    writeBlock(mFormat.format(1));
    let leadOutCL = CLs.filter((CL) => CL.movement == MOVEMENT_LEAD_OUT);
    leadOutCL[0].args.feed = 0;
    pendingRadiusCompensation = -1;
    ProcessCuttingLine(leadOutCL[0]);
    pendingRadiusCompensation = -1;
    //leadOutCL.forEach((CL) => { ProcessCuttingLine(CL); });

    writeBlock(mFormat.format(0));
    writeBlock(mFormat.format(91));
    forceMotion();
    if (!isLastSection()) writeBlock(gFormat.format(40), gFormat.format(1), initialPosition.x, initialPosition.y, feedOutput.format(800.));
}

var onClose = () => {
    writeBlock(gFormat.format(40), gFormat.format(1), xOutput.format(firstInitialPosition.x), yOutput.format(firstInitialPosition.y), feedOutput.format(800.));
    writeBlock(mFormat.format(2));
    writeln("%");
    
    //GenerateMovementTypeList();
}


const sectionAmount = 2;

const PropertyGen = () => {
    const P = {
        separateWordWithSpace: {
            title: "SeparateWordWithSpace",
            group: "format",
            type: "boolean",
            value: true,
            default: true
        },
        useGModal: {
            title: "Use G Modal",
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
    const movements = { MOVEMENT_RAPID, MOVEMENT_LEAD_IN, MOVEMENT_CUTTING, MOVEMENT_LEAD_OUT, MOVEMENT_LINK_TRANSITION, MOVEMENT_LINK_DIRECT, MOVEMENT_RAMP_HELIX, MOVEMENT_RAMP_PROFILE, MOVEMENT_RAMP_ZIG_ZAG, MOVEMENT_RAMP, MOVEMENT_PLUNGE, MOVEMENT_PREDRILL, MOVEMENT_REDUCED, MOVEMENT_FINISH_CUTTING, MOVEMENT_HIGH_FEED };
    Object.keys(movements).forEach((key) => {
        writeln(`${movements[key]}: ${key}`);
    });
}