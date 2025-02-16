certificationLevel = 2;
description = "TSUKURIKAKE";

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
    return { movement, args, start };
}

const GetFeed = (feed) => {
    return feed ? feedOutput.format(feed) : "";
}

var onLinear = (...args) => {
    const [ x, y, z, feed ] = args;
    const CL = GetCL({ x, y, z, feed });
    CL.type = LINEAR;
    CLs.push(CL);
}

var onCircular = (...args) => {
    const [ clockwise, cx, cy, cz, x, y, z, feed ] = args;
    const CL = GetCL({ clockwise, cx, cy, cz, x, y, z, feed, isfullCircle: isFullCircle() });
    CL.type = CIRCULAR;
    CLs.push(CL);
}

var onMovement = () => {
    CLs.push({ "change": movement });
}

var onRadiusCompensation = () => {
    CLs.push({ radiusCompensation });
}

const ProcessLinear = (CL) => {
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

const ProcessCircular = (CL) => {
    if (pendingRadiusCompensation >= 0) {
        writeln("ERROR: radius compensation not supported for circular motion");
        return;
    }

    if (CL.isFullCircle) {
        writeln("ERROR: full circle not supported");
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

const ProcessCuttingLine = (CL) => {
    if (CL === undefined) {
        writeln("undefined");
        return;
    }
    if (CL.radiusCompensation !== undefined) {
        if (pendingRadiusCompensation === -1) {
            pendingRadiusCompensation = CL.radiusCompensation;
        }
        else {
            writeln("ERROR: radius compensation already set");
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

const Preparing = (CL) => {
    initPos.x = xOutput.format(CL.args.x);
    initPos.y = yOutput.format(CL.args.y);

    if (globalIndex !== 1) writeBlock(gFormat.format(1), initPos.x, initPos.y, feedOutput.format(800.));
    writeln("(Section: " + globalIndex +")")
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

const PartingOff = (CL) => {
    writeBlock(mFormat.format(1));

    CL.args.feed = 0;
    ProcessCuttingLine(CL);

    writeBlock(mFormat.format(91));
    writeBlock(mFormat.format(0));

    forceAny();
    writeBlock(gFormat.format(40), initPos.x, initPos.y, feedOutput.format(500.));
}

const ProcessBlock = (block) => {
    let runUp;
    let cutting;
    let leadOut;
    runUp = block.filter( CL => CL.movement === MOVEMENT_LINK_TRANSITION || CL.movement === MOVEMENT_CUTTING || CL.movement === MOVEMENT_LEAD_IN);
    runUp[0] = runUp[runUp.length - 1];
    cutting = block.filter( CL => CL.movement === MOVEMENT_FINISH_CUTTING || CL.radiusCompensation !== undefined );
    leadOut = block.filter( CL => CL.movement === MOVEMENT_LEAD_OUT );

    pendingRadiusCompensation = -1;
    Preparing(runUp[0]);
    for (const CL of cutting) {
        ProcessCuttingLine(CL);
    }
    pendingRadiusCompensation = -1;
    PartingOff(leadOut[0]);
}


var onOpen = () => {
    if (getProperty("separateWordWithSpace"), false) setWordSeparator(" ");
    else setWordSeparator("");

    if (getProperty("UseGModal"), false) gMotionModal = createModal(gFormat);
    else gMotionModal = createModal({ force: true }, gFormat);

    writeln("%");
}

var onSection = () => {
    CLs = [];
}

var onSectionEnd = () => {
    const blocks = [];
    let currentBlock = [];
    let leadOutMovement = undefined;

    for (const CL of CLs) {
        if (CL.change && leadOutMovement) {
            blocks.push(currentBlock);
            currentBlock = [];
            leadOutMovement = undefined;
        }

        if (CL.change === 3) {
            leadOutMovement = true;
        }

        currentBlock.push(CL);
    }

    //blocks.forEach( block => { block.forEach( leaf => writeln(JSON.stringify(leaf)) )});

    for (const block of blocks) {
        ProcessBlock(block);
        globalIndex++;
    }
}

var onClose = () => {
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
