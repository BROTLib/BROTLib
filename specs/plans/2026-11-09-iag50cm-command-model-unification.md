# IAG50cm command handling on MONETcommon's model (BROTLib#25, follow-up of the 2026-10-21 plan)

**Status: proposed, nothing implemented, compiled or run.** Written 2026-11-09 from the code only. It carries out rows 4.4(b)/(c)
and 5.3b of `2026-10-21-telescope-state-machine-unification.md` ("Remaining work 2026-11-06") and prepares 5.4 there. That plan's
table is not edited by this PR; it should link here once this plan is accepted.

**Decision this plan implements (Tim, 2026-11-09):** where IAG50cm and MONETcommon differ in the command path, MONETcommon's
behaviour wins: reset abort, command acceptance at arrival, emergency park on a new hardware error, park beats power-on. Already
merged on IAG50cm `develop`: IAG#213 (`FB_TelescopeControl EXTENDS BROTLib.FB_RaDecTelescopeControl`), IAG#215
(`BROTLib.FB_StopTransaction`, pin BROTLib 0.19.0, `abSweeping`), IAG#216 (a new HA/Dec/focus error calls `Park()` through
`BROTLib.F_ErrorParkRequest`).

**Base commits** (read 2026-11-09): IAG50cm `origin/develop` `5185aca` (ProjectVersion 0.7.0, pins BROTLib 0.19.0; the local
`develop` checkout is 4 commits behind, its line numbers are about 17-19 lower after line 223), MONETcommon `develop` `1f7e672`,
BROTLib `develop` `2c70d0d` (0.19.0).

**Marking.** **[verified]** = read in the code at the commits above, with `file:line` (`.TcPOU` line numbers, XML wrapper
included); **[unverified]** = assumption or TwinCAT behaviour, to be settled by CI or on site; **[design]** = proposed here, not
in any code yet. Short names: **I** = `IAG50cm/IAG50cm/POUs/FB_TelescopeControl.TcPOU`, **M** =
`MONETcommon/MONETcommon/MONETcommon/FB_MonetTelescopeControl.TcPOU`, **B** = `BROTLib/BROTLib/BROTLib/Telescope/FB_BaseTelescopeControl.TcPOU`,
**A** = `BROTLib/.../Telescope/FB_CommandArbiter.TcPOU`, **CA** = `BROTLib/.../Telescope/Command/F_CommandAcceptance.TcPOU`,
**T** = `IAG50cm/IAG50cmTests/IAG50cmTests/IAG50cmTests/POUs/`. Issue numbers: **IAG#n** = IAG50cm, **MC#n** = MONETcommon,
**BL#n** = BROTLib. IAG and MONET issue numbers collide (IAG#84 "park in a limit" is not MC#84 "stop clears every flag"); the
comments in I use bare `#n` for IAG issues.

## 1. Purpose and scope

Put IAG50cm on the command model MONETcommon has since MC#199 (step 5 of `MONETcommon/specs/plans/2026-11-02-reference-implementation-issue-24.md`)
and MC#210 (BL#25 step 5.2), so that both telescopes run the same skeleton: read-only edge-triggered command inputs, request latches
`b*Active` set by the methods and by input edges, acceptance at arrival (`F_CommandAcceptance`), supersede ("latest move wins"), the
abort stop `bMoveAbortPending`, stop release on a settled transaction, reset abort (`F_ResetMoveAbort`) and `BROTLib.FB_CommandArbiter`
with `bParkWinsOverPowerOn := TRUE`. After that, the shared skeleton can move into `FB_BaseTelescopeControl` (BL#25 step 5.4), which
this plan keeps as a checkpoint (step 4).

**In scope:** I (body arbitration, command methods, `_HandleReset`, stage-machine guards where they read the inputs, events and
telemetry that read the inputs), the IAG50cmTests rig suites, the IAG repo ADS tools/runbooks that read or write the inputs.

**Out of scope:** focus behaviour (MC#122 line stays as it is: `Stop()` stops the focus, park stage 80 waits for it); SoE reset
unification (BL#67); telemetry (`_SendTelemetryEquitorial`, only its read of `bSlew` I:1940 is renamed); stage-machine guard
policy (IAG's `bReset OR bError OR bStop OR bInterupted` prologues stay; `F_StageAbort` stays in MONETcommon); IAG fixes MONET lacks
(timeouts counted only while dispatched IAG#75 I:448-451, 12 h idle park fires once IAG#83 I:475-480, all errored axes reset IAG#11,
horizon guard gated on ready IAG#82): they stay in IAG and are decision-3 items "IAG's fix goes to MONET" of the 2026-10-21 plan,
not touched here; any BROTLib change (none needed for steps 1-3, see 7).

## 2. Where IAG50cm stands [verified unless marked]

- **The block uses the inherited command inputs as its own state.** B:12-26 documents `bPower`..`bReset` as edge-triggered and
  never written by the telescope control. I writes them in 64 assignments (42 in the body, 22 in stage machines and command
  methods; grep of `^\s*b<input>\s*:=`), plus `rtrigReset(..., Q=>bReset)` I:1201 and `bPower := fbStartup.BeginScan(...)` I:148.
  Kinds: error clears (I:213-217), automatic stops (`bStop := TRUE`: no valid time I:157-159, calibration lost I:352-354, horizon /
  pole limit I:376-391, target below horizon / in pole zone I:409, I:430), automatic requests (`bGoHome := TRUE` limit home I:379,
  I:388, power-on stage 100 I:1870; `bPark := TRUE` 12 h idle I:476; `Park()` on a new error I:236-238), arbitration clears
  (I:498-768), stage-machine ends and timeouts (I:1286, 1391-1393, 1418, 1508, 1519, 1545, 1680, 1771-1867, 2109, 2219), stop and
  reset release (I:1007-1014), reset drop (I:1229-1231), methods (I:2457 `Home`, 2486 `Init`, 2499 `Park`, 2618 `Slew`, 2626 `Stop`,
  2652 `Track` sets `bGoto`). 152 references to the eight names in I in total.
- **User stop vs automatic stop** is told apart by `bUserStop` (I:74, set in `Stop()` I:2625, read I:359, 502, 515, cleared I:786).
- **Callers.** IAG `MAIN` instantiates the block, writes only `bSafetyAckRequest` and `bStartupAxisReset` and passes it to the comm
  layer and to dome/pendant as interfaces (`IAG50cm/IAG50cm/POUs/MAIN.TcPOU:30-83`). `BROTLib.FB_Comm_MQTT_Influx` calls only
  `Init/Park/Home/Track/Slew/Stop/Reset` and the offset properties through `I_Telescope`/`I_RaDecTelescope`
  (`BROTLib/.../POUs/Comm/FB_Comm_MQTT_Influx.TcPOU:127-162, 287-291, 315`). Dome and pendant use only the offset properties
  (`DomeControl/FB_DomeControl.TcPOU:6`, `PendantControl/States/*:45-59, 176, 270`). The rig suites drive the block through the
  methods only (`T/Iag*_Tests.TcPOU`, every command is `rig.fbTel.<Method>()`), and read the inputs in 56 places (`bPark` 24,
  `bSlew` 17, `bStop` 9, `bPower` 6, `bGoHome` 2).
- **B's own default methods write the inputs** (B:341 `Home`, 348 `Init`, 355 `Park`, 364 `Reset`, 401 `Slew`, 408 `Stop`,
  421 `Track`), against B:12-26. I overrides all seven (I:2453-2652), so they never run for IAG. A BROTLib cleanup, noted for step 4.
- **B declares `bInterrupted`** (B:67); I uses its own `bInterupted` (I:69). Two flags with near-identical names; harmless today,
  a trap for step 4.
- **What already matches MONET:** a park aborts a *running* power-on (IAG#109, I:486-499; A:104-112 with TRUE); new hardware error
  starts the park (IAG#216, I:226-239; M:710-722); `BROTLib.FB_StopTransaction` (IAG#215, `_SetStopTxInputs` I:2227-2251); the
  interrupted stage machines are reset by a one-shot `bInterupted` (I:686-690, M:821-841); error clears the move requests (I:213-217,
  M:599-603).

## 3. Target end state for IAG50cm

1. **Request latches** (read-only `VAR_OUTPUT`, names and comments as M:79-93): `bPowerActive`, `bGoHomeActive`, `bParkActive`,
   `bTrackActive`, `bGotoActive`, `bSlewActive`, `bStopActive`, `bResetActive`. Every read and write of an input in I becomes a read
   or write of its latch. I never writes `bPower`..`bReset` again.
2. **Edges.** `b*Checked` (VAR) = the input of the last scan, snapshot at the end of the body (M:1031-1038), set TRUE by the method
   of that command. Start of the body: rising `bStop`/`bPark`/`bReset`/`bPower` call `Stop()`/`Park()`/`Reset()`/`Init()` in that
   order (M:342-359). Rising `bGoHome`/`bGoto`/`bSlew`/`bTrack` are decided by `_AcceptMove` after the error computation (M:570-597).
   `Track()` marks `bGoto` and `bTrack` as decided (M:2943-2946).
3. **Acceptance at arrival.** `_CommandState`, `_AcceptMove`, `_NoteRejected` as M:2999-3080; `BROTLib.F_CommandAcceptance`
   (CA:21-60) decides `Home`, `Track`, `Slew` and the move edges before anything is written; a rejection is logged as M:2009-2025
   (`BROTLib.F_TCSCommandText`, `BROTLib.F_CommandRejectText`, one line per identical rejection in 2 s). `Park` is never rejected
   (CA:21-29). Internal requests (limit home, power-on stage 100, idle park, error park) set the latch directly, as MONET's horizon
   guard does (M:638-644).
4. **Supersede.** `replace` sets `bSupersedeRequest`/`eSupersedeKeep` (M:3046-3049); the block at M:678-708 drops the other move
   latches, interrupts home/goto/slew once, restarts the kept command's 600 s timer and sets `bMoveAbortPending` (no error).
5. **Abort stop** `bMoveAbortPending` (replaces IAG's `bStopping`, I:70): set by the supersede, by the arbiter
   (`bSetMoveAbortPending`) and by the reset abort; dispatched as `stop` by the arbiter (A:120-124); cleared by the release when the
   transaction has settled and `TCS_command = stop` (M:2426-2433), by an error (M:604), never by a new request.
6. **Stop.** `bStopActive` is released only when the stop transaction has settled (`_StopTxRelease`, M:2419-2441); a repeated
   `Stop()` restarts the transaction for axes that move again (`fbStopTx.Restart()`, M:2924-2931); a stop clears every move request
   and resets every stage machine (A:84-102, MC#84); any stop aborts a power-on (A:84-91).
7. **Park and power-on.** `Park()` during a stop queues in `bParkAfterStop`, released at settle (M:2763-2777, 2434-2438); `Stop()`
   drops a queued park (M:2923, MC#213); `Init()` is refused with a logged reason while a stop or park is pending (M:2681-2716); the
   arbiter runs with `bParkWinsOverPowerOn := TRUE` (M:793).
8. **Reset abort.** Every reset (method, input edge, cabinet key) drops goto/slew/track/gohome, sets `bMoveAbortPending :=
   BROTLib.F_ResetMoveAbort(...)`, resets the stage machines and recovers a stuck stop (M:2062-2111). IAG's hardware part (safety
   acknowledge request, axis reset passes) stays gated as today (open question Q1).
9. **Arbiter.** `fbArbiter : BROTLib.FB_CommandArbiter` replaces the IF/ELSIF chain I:483-786, wired as M:779-859, with
   `bStopped := bSettled` (IAG#98 gate), `bEmergencyPark := FALSE`, and the IAG park pre-step and post-hooks below. [design]

### What stays IAG-specific, and where it lives afterwards

| Feature (issue) | Today [verified] | After this plan [design] |
|---|---|---|
| Calibration sweep stop `FB_SweepStop` (IAG#113, #197, #198) | arm on power-on abort I:492-496, 510-514; `ArmAll` I:654-656; block I:918-932 | post-hook after the arbiter: when `bInterruptPower` and `_PowerOn() >= 40`: `Arm()` (stop) or `ArmAll()` (`bPowerAbortedByPark`), plus `bStopSweep` on both axes; `ArmAll` in the park pre-step; block I:918-932 unchanged |
| Park in a limit, home first (`bLimitHome`, `bParkAfterHome`, `bParkHomeDone`, IAG#84) | I:365-392, 658-679, 1501-1507 | park pre-step holds the park from the arbiter while `bGoHomeActive AND bLimitHome`; limit blocks unchanged except that they set `bGoHomeActive` and stop through `_AutoStop()` |
| A pending park survives an automatic limit stop (IAG#84) | I:515, comment I:526 | `_AutoStop()`: `bStopActive := TRUE`, a pending `bParkActive` moves to `bParkAfterStop` (Q2) |
| In-place park with axes off / in error / E-stop (`bSafeParked`, `bParkedInPlace`, IAG#54, #57, #110, #187, #196, #200) | I:567-652 (branch), I:944-989 (state) | park pre-step before the arbiter consumes `bParkActive` exactly as I:567-652 does; state block I:944-989 unchanged; the arbiter's park-in-error branch (A:128-130) is never reached on IAG |
| Park with no completed power-on (IAG#197) | I:654-656 | park pre-step: `fbSweepStop.ArmAll()`, park held from the arbiter |
| `tonParkPending`, `bParkForceInPlace` (IAG#197) | I:467-474 | stays; reads `bParkActive`, `bMoveAbortPending` instead of `bPark`, `bStopping` |
| `tonHomePending`, `FB_HomeDropReason` (IAG#75, #108) | I:455-464 | stays on `bGoHomeActive`; after step 2 only internal homes can be pending (a `Home()` while not ready is rejected) |
| `bRestartGoto`/`bRestartSlew` (IAG#41) | I:71-72, 745-768, 2617, 2651 | removed; supersede does the same (abort stop, restart, timer restart) |
| Home during tracking (IAG#72) | I:720-724 | removed; `Home()` while tracking is `replace` (`bTracking` is in `bMoveActive`, M:3019-3024), abort stop, then home |
| Preemption stop only if the preempted command moves (IAG#43 `bStopping`) | I:693-695, 716-718, 742-744, 558-565 | `bMoveAbortPending`, set on every preemption (A rule); a stop with nothing moving settles after 3 scans at rest (BL#160 rule) |
| Power-on hold of the limit stops (IAG#166) | I:359, 376, 385 | stays; `bUserStop` term dropped (any stop aborts a power-on anyway) |
| Calibration-lost stop (IAG#161) | I:350-354 | stays, through `_AutoStop()` |
| Reset hardware part: safety acknowledge, axis reset passes (IAG#11, #36, #55, #59, #103) | I:183-196, 1201 | stays, gated on `bError OR bSafetyAckPending` (Q1) |
| Cabinet reset key | I:1201 (`fbCabinet.Reset`) | an edge source of the reset, like `Reset()` |
| Power-on aborted by park log (IAG#109) | `bPowerParked` I:93, 487 | set from `fbArbiter.bPowerAbortedByPark` |
| Stop ignored during the in-place park (IAG#196) | I:537-540 | post-hook: a new `bStopActive` while `bSafeParked` logs it; the stop does not touch `bSafeParked` |
| Park/home end texts (IAG#57, #75), stop timeout log (IAG#120) | `_LogEvents` I:1045-1188, I:886-916 | unchanged; triggers read the latches |
| Focus handling (MC#122) | `Stop()` I:2629-2631, park stage 80 | unchanged (out of scope) |

## 4. Divergence table (command path)

"Step" = where this plan implements it; "Pin" = the test that pins the result (existing tests in `T`, new ones marked *new*).
MONET-side pins are the MONETcommonTests suites of the same name (`MonetStopDuringSlew_Tests`, `MonetParkDuringPowerOn_Tests`,
`MonetResetUnderMotion_Tests`, `MonetErrorPark_Tests`, `FB_MonetRig_Tests`).

| # | Behaviour | IAG today | MONET | Decision | Step | Pin (IAG) |
|---|---|---|---|---|---|---|
| D1 | Command inputs are state, written by the block | I:148, 157-159, 213-217, 352-391, 476, 498-768, 1007-1014, 1201, 1229-1231, methods 2457-2652 [verified] | read-only, edges M:342-359, 570-597, latches M:79-93, snapshot M:1031-1038 [verified] | MONET (B:12-26 contract) | 1a, 1b | *new* `FB_IagRig_Tests`: held input once, falling input no-op, method + edge once |
| D2 | Acceptance at arrival | `Slew`/`Track` refuse only "not ready" I:2610-2614, 2644-2648; `Home` I:2457, `Park` I:2499 unconditional [verified] | `_AcceptMove` M:3027-3054, `_CommandState` M:2999-3026, CA:21-60 [verified] | MONET | 2 | *new* `IagCommandAcceptance_Tests` |
| D3 | Rejection log | one WARN per refusal, own text (`TCScommandRefusedEvent`, I:2611, 2645) [verified] | `<cmd> rejected: <reason>`, identical one logged once per 2 s M:2009-2025 [verified] | MONET | 2 | *new* `Rejection_Repeated_Within_2s_Is_Logged_Once` |
| D4 | Home while not ready | latched, dropped after 2 min with a WARN (I:455-464) [verified] | rejected `not_ready` (CA:51-54) [verified] | MONET (internal homes keep the 2 min drop) | 2 | *new* `Home_While_Not_Ready_Is_Rejected` |
| D5 | A move during a park / gohome / stop | set, then dropped silently by the park branch I:681-685, the gohome branch I:709-711, the stop branch I:527-534 [verified] | rejected `parking` / `gohome_active` / `stopping` with a log (CA:39-58) [verified] | MONET | 2 | *new* `Slew_During_Park_Is_Rejected`, `Goto_During_GoHome_Is_Rejected`, `Slew_During_Stop_Is_Rejected` |
| D6 | Latest move wins | fixed precedence: a `Slew()` during a goto is dropped by the goto branch (I:734-744); same-command retarget by `bRestartGoto`/`bRestartSlew` (IAG#41, I:745-768) [verified] | `replace` -> supersede M:678-708, 3046-3049 [verified] | MONET | 3C.1 | *new* `Slew_During_Goto_Replaces_It`, `Track_During_Goto_Retargets` (IAG#41) |
| D7 | Home during tracking | own branch, stop then home (IAG#72, I:720-724) [verified] | `replace` because `bTracking` is a move (M:3019-3024) [verified] | MONET mechanism, same outcome | 3C.1 | *new* `Home_During_Track_Stops_Then_Homes` |
| D8 | Abort stop on preemption | `bStopping` only if the preempted command is the dispatched one (I:693-695, 716-718, 742-744) [verified] | always (A:84-160 `bSetMoveAbortPending`; M:705, 842-844) [verified] | MONET | 3A.5 | *new* `Park_Over_A_Waiting_Goto_Runs_A_Short_Abort_Stop` |
| D9 | What a stop clears | first flag of an ELSIF chain (I:515-537) [verified] | every move request and every stage machine (A:84-102, MC#84) [verified] | MONET | 3A.3 | *new* `Stop_Clears_Every_Pending_Move` |
| D10 | Stop release | `IF bStopped THEN bStop := FALSE` (I:1007-1009) [verified] | on a settled transaction (M:2419-2441, call M:987, MC#96) [verified] | MONET | 3A.2 | `IagStopDuringSlew_Tests.Stop_Clears_The_Slew_And_Settles` (stays), *new* `Stop_Is_Held_Until_The_Transaction_Settles` |
| D11 | Repeated stop | no effect, `bStop` already TRUE (I:2625-2626) [verified] | `fbStopTx.Restart()` for axes moving again (M:2924-2931, MC#96 D2) [verified] | MONET | 3A.4 | *new* `Repeated_Stop_Restarts_Only_Moving_Axes` |
| D12 | Automatic stop and power-on | only a user stop takes the stop branch (I:502, IAG#27), but `_PowerOn` aborts on any `bStop` (I:1780); limit stops held while still (IAG#166, I:359) [verified] | any stop aborts the power-on (A:84-91) [verified] | MONET; practically unchanged, #166 hold stays | 3B.2 | `IagParkDuringPowerOn_Tests.Stop_During_PowerOn_Aborts_The_Startup` (stays), *new* `Automatic_Stop_In_A_Moving_PowerOn_Aborts_It` |
| D13 | Park during a stop | cleared unless automatic limit stop (I:515-525) [verified] | queued `bParkAfterStop`, runs at settle; `Stop()` drops it (M:2763-2777, 2434-2438, 2923) [verified] | MONET, plus IAG#84 kept (Q2) | 3B.1 | `IagParkInLimit_Tests` (both stay), `IagStopDuringPark_Tests` (stays), *new* `Park_During_Stop_Runs_After_Settle`, `Stop_Drops_A_Park_Queued_Behind_A_Stop` |
| D14 | Park vs a power-on that is requested but not yet running; `Init()` during a park | `Init()` cancels the park (I:543-556); the park aborts only a dispatched power-on (`TCS_command = poweron`, I:486) [verified] | park wins in both orders: `Init()` refused while stop/park pending (M:2684-2693), A:104-112 with TRUE, CA:25-27 [verified] | MONET | 3B.3, 3C.2 | `IagParkDuringPowerOn_Tests.Park_During_PowerOn_Aborts_The_Startup_And_Parks` (stays), *new* `Init_During_Park_Is_Refused`, `Init_During_Stop_Is_Refused`, `Park_Right_After_Init_Aborts_The_PowerOn` |
| D15 | `Init()` clears stale move requests | no (I:2484-2492) [verified] | yes (M:2696-2700, MC#85) [verified] | MONET | 3B.3 | covered by `Init_During_Park_Is_Refused` neighbour case (*new* `Init_Drops_A_Stale_Home`) |
| D16 | Reset without an error | ignored: trigger gated on `bError OR bSafetyAckPending` (I:1201, IAG#36, #59) [verified] | acts on every reset (M:2060, 2081-2111; held while error M:989-997) [verified] | MONET for the request part, hardware part gated (Q1) | 3B.4 | flips `IagResetUnderMotion_Tests.Reset_Without_An_Error_Is_Ignored` |
| D17 | Reset under motion | drops goto/slew/track, keeps gohome, the running move goes on (I:1229-1231) [verified] | drops all four (MC#85), abort stop via `F_ResetMoveAbort`, park kept (M:2088-2101) [verified] | MONET | 3B.4 | flipped test above, *new* `Reset_At_Rest_Drops_A_Pending_Move`, `Reset_During_Park_Keeps_The_Park` |
| D18 | Stuck stop and reset | none; the 30 s forced release (IAG#120, I:886-916) is the only exit [verified] | reset recovers a stop stuck in Stopping at rest (M:2062-2079) [verified] | MONET (additive to IAG#120) | 3B.5 | `IagStuckStop_Tests` (stays), *new* `Reset_Recovers_A_Stuck_Stop` |
| D19 | Emergency park on a new hardware error | done, IAG#216 (I:226-239), carried out as IAG's in-place park | M:710-722 [verified] | MONET (done) | - | `IagErrorPark_Tests.Axis_Error_Starts_The_Park_Without_Moving_The_Mount` |
| D20 | Error clears | move flags (I:213-217) [verified] | also `bMoveAbortPending`, `bSupersedeRequest` (M:604-605) [verified] | MONET | 3A.1, 3C.1 | *new* `Error_During_Abort_Stop_Clears_It` |
| D21 | Arbitration order | user stop > park aborts running power-on > power > `bStopping` > park > gohome > goto > slew > track (I:486-782) [verified] | stop > park aborts power-on > power > abort stop > park > gohome > goto > slew > track (A:84-160) [verified] | MONET; IAG park variants via the pre-step | 3C.2 | every suite green unedited by that commit |
| D22 | Park in an error | in-place park, mount not moved, `_ParkTelescope` returns on `bError` (I:567-652, 1550) [verified] | emergency park dispatched (A:128-130), stage 0 of M's park | **stays IAG (site)**: an IAG axis error disables the drives | - | `IagErrorPark_Tests` (stay) |

Not command-path, stay as they are: idle 12 h park (I:475-480 vs M:656-658), state-machine timeouts (I:448-451 vs M:653-655),
axis reset of all errored axes (I:183-196 vs M:411-434).

## 5. Steps

Every step: branch from IAG50cm `develop`, one PR, CI (`tcbuild.yml`: IAG50cm build, IAG50cmTests on mock axes) green, merge.
Each behaviour change is its own commit with its own test; a rig assertion that pins the old behaviour is changed in the same commit
that flips it (same method Id, name changed). Nothing is run locally (no XAE, tctool or TcXaeShell). Expect 1-3 CI re-runs per PR
(IAG#215 needed four for runner failures: missing pin, runtime timeout, XAE COM start, XAE open timeout); a red run is only a finding
after the log shows a test failure, not a runner failure.

**Order and why.** 0 first because a writer of the inputs decides whether step 1 is allowed. 1 is a rename plus edges and stays
neutral for every method caller. 2 (acceptance) before 3 (arbiter) because acceptance removes states the arbiter would otherwise see
(moves during a stop, park or gohome) and its `replace` row can be mapped to IAG's existing preemption for one release. In 3 the
behaviours are first aligned **inside the old IF/ELSIF chain**, one commit per divergence, and only then is the chain swapped for the
arbiter (3C.2) as a commit that should flip nothing. Some code of 3A/3B is rewritten in 3C.2; the price is a few hundred lines, the
gain is that every test flip has its own commit and the swap is checkable by "all suites green, none edited".

### Step 0: survey of writers and readers of the eight inputs (no code; results appended here)

Done while writing this plan [verified]: comm layer (methods only, see 2), IAG `MAIN`, dome and pendant (no access), IAG rig suites
(methods only, 56 reads), `IAG50cm/IAG50cm/VISUs/Safety.TcVIS` (binds `GVL_Safety.ErrAck/Restart`; no `telescopeControl` found by a
case-insensitive grep). Found readers: the IAG repo ADS tools read `MAIN.telescopeControl.b*` (`IAG/tools/Ads-Watch.ps1:34`,
`Ads-Watch-t21.ps1:34`, `Ads-Watch-t36.ps1:41`, `Ads-Capture.ps1:37`, also `bInterupted`, `bStopping`). Found writers (procedures,
not code): `IAG/specs/plans/2026-10-06-iag50cm-cold-start-test-on-new-libraries.md:22` (`bPower := TRUE` over ADS) and
`2026-10-09-iag50cm-telescope-test-plan.md:94` (`bReset := TRUE` over ADS).

Survey result (2026-11-09, repos on the build PC) [verified for what is in the repos; the items marked "ask Tim" are not]:
- [x] BROTweb / HMI gateway: no configuration routes to the IAG50cm PLC. A grep of `BROTweb` (without `Packages`), `HmiSpike`,
  `BROTLib-wt-hmitier` and `AstroBROT` finds no `telescopeControl.b(Power|Park|GoHome|Goto|Slew|Track|Stop|Reset)`; the server configs
  hold no such symbol. `BROTweb/docs/design.md:175` states that the 26 old `MAIN.TelescopeControl.*` mappings (direct writes of
  `bInit`/`bPark`/`bSlew`/`bTrack`) are not carried over, and `docs/m1/symbols.md:63` excludes the internal flags. The middle tier uses
  the methods. **No writer.**
- [ ] The IAG50cm control PC (scripts, XAE watch lists, a Visu outside the repo): not visible from the repos. **Ask Tim.**
- [ ] pyBROT / pyobs-brot / brotgui: no code of them on the build PC; MC 4c says MQTT verbs only. **Ask Tim** whether the IAG deployment
  uses the same clients.
- [ ] Visu `Safety.TcVIS`: only the grep done earlier. **Tim** opens it once in XAE or greps the XML for `telescopeControl`.
- [x] Readers: the live IAG ADS tools `Ads-Watch.ps1` and `Ads-Capture.ps1` now also read the `b*Active` latches
  ([IAG#18](https://github.com/BROTLib/IAG/pull/18), merge with the release). The dated copies (`Ads-Watch-t21/-t36`, `docs/data`) stay.
- [x] Writers in procedures: only the two runbook lines named above (`bPower := TRUE`, `bReset := TRUE` over ADS); both are one-shot
  writes, so the procedure note applies: an ADS write is a one-shot edge, write FALSE before the next TRUE, prefer the MQTT verb.

Outcome per finding: **no writer** -> step 1 as written. **Reader** (ADS tools) -> change it to `b*Active` in an IAG repo PR merged with
the step-1 release. **Writer that relies on the block clearing the flag** (button/TOGGLE pattern) -> change it to the MQTT verb or to a
helper bit in `MAIN` that calls the method (MONETS#72 pattern) and release both together; if it cannot be changed, hold step 1 and ask
Tim. **Writer that writes TRUE once** (runbooks) -> procedure note: an ADS write is a one-shot edge, write FALSE before the next TRUE;
prefer the MQTT verb. Release: none. Effort: S.

### Step 1a: request latches for stop, park, power, reset (PR 1)

- **Files:** I; `T/FB_IagRig.TcPOU` (setters `SetStopInput`, `SetParkInput`, `SetPowerInput`, like MONET's `SetSlewInput`);
  `T/FB_IagRig_Tests.TcPOU`; the suites that read `bStop`/`bPark`/`bPower` (mechanical); `IAG50cmTests/README.md` (one line).
- **Change:** declare `bPowerActive`, `bParkActive`, `bStopActive`, `bResetActive` (VAR_OUTPUT) and `bPowerChecked`, `bParkChecked`,
  `bStopChecked`, `bResetChecked` (VAR). Edge block at the top of the body (before `_ReadAxes` I:145): `IF bStop AND NOT bStopChecked
  THEN Stop(); ...` order stop, park, reset, power. Methods set `b*Checked := TRUE` first, then the latch: `Stop()` -> `bStopActive`
  (keeps `bUserStop` until 3B.2), `Park()` -> `bParkActive`, `Init()` -> `bPowerActive`, `Reset()` keeps `bResetRequest`; the
  trigger I:1201 writes `Q=>bResetActive`. Every other read/write of the four inputs becomes the latch (scripted rename outside
  comments and strings, checked by diff, as MC#199 did): `BeginScan(Power := bPowerActive)` I:148, automatic stops, the arbitration,
  stage machines, release I:1007-1014, `Parking :=` I:993, events I:1075, 1101. Snapshot `b*Checked := b*` at the end of the body.
- **Tests:** one commit renames the 39 reads (`bPark` 24, `bStop` 9, `bPower` 6) to the latches, no assertion changed. One commit
  adds to `FB_IagRig_Tests`: `Held_Stop_Input_Stops_Once`, `Park_Input_Edge_Parks_Like_Park`, `Stop_Method_And_Input_Edge_In_One_Scan_Count_Once`,
  `Power_Input_Is_Not_Written_By_The_Block`.
- **Acceptance:** CI green; every existing suite green with only the rename edit; grep shows no assignment to `bStop`, `bPark`,
  `bPower`, `bReset` in I.
- **Neutral?** Yes for MQTT/method callers. Not for an ADS writer: a held input is one command and is never cleared (step 0).
- **Risk:** low-medium: a missed rename compiles (the input still exists) and silently reads a never-cleared input. Mitigation: the
  grep in the acceptance, plus a review of every remaining read of the input names (only the edge block and the snapshot may read them).

### Step 1b: request latches for the moves (same PR as 1a or PR 2)

- **Files:** as 1a (`SetSlewInput`, `SetSlewTargetInput`).
- **Change:** `bGoHomeActive`, `bGotoActive`, `bSlewActive`, `bTrackActive` and their `b*Checked`. A rising move input sets its latch
  exactly as a direct write did before (no gating yet; step 2 routes the edges through acceptance). Rename every read/write in the
  body (I:157, 213-217, 365-391, 395-430, 448-474, 498-782), stage machines (I:1286, 1391-1393 `bTrackActive := bAutoTrack`, 1418,
  1508, 1519, 1870, 2109, 2219), `_HandleReset` I:1229-1231, events I:1061, 1089, 1095, telemetry I:1940, methods I:2457, 2617-2618,
  2651-2652 (`bRestart* := b*Active`).
- **Tests:** rename of 19 reads (`bSlew` 17, `bGoHome` 2); new in `FB_IagRig_Tests`: `Held_Slew_Input_Starts_The_Slew_Once`,
  `Slew_Input_Falling_Does_Not_Abort_The_Slew`, `Slew_Method_And_Input_Edge_In_One_Scan_Count_Once` (copies of the MONET cases).
- **Acceptance, neutral, risk:** as 1a. `FB_IagRig_Tests` grows from 2 to 9 tests.
- **Release (1a+1b):** IAG50cm minor (0.8.0; semantics change for ADS writers), tag only. IAG repo ADS tools updated in the same window.

**On-site check after step 1 (IAG50cm):**
- [ ] 1. Power-on from parked, slew, `stop=1` during the slew, park, reset after an error (errored axes reset, second pass about 2.5 s later)
- [ ] 2. `Ads-Watch.ps1` shows `bSlewActive`, `bStopActive`, `bParkActive` following the commands; the inputs stay FALSE
- [ ] 3. Optional, with Tim: ADS write `bStop := TRUE` held for 5 s during a slew: one stop; write FALSE: nothing happens
- [ ] 4. Normal use over a night: no new warning in the log

### Step 2: acceptance at arrival (PR 3)

- **Files:** I; new suite `T/IagCommandAcceptance_Tests.TcPOU` (suite 18 of 32) and its line in `T/MAIN.TcPOU`; `IAG50cmTests.plcproj`.
- **Change:** methods `_CommandState` (IAG fill: `bEstop := bEstopTriggered`, `bError`, `bClockValid := fbTime.bValid`, `bStop :=
  bStopActive`, `bPowering := bPowerActive OR fbStartup.Initializing`, `bParkPending := bParkActive` (plus `bParkAfterStop` in 3B.1),
  `bIsParked`, `bReady`, `bGoHomeActive := bGoHomeActive OR TCS_command = gohome`, `bMoveActive` as M:3019-3024 with `bStopping`
  standing in for `bMoveAbortPending` until 3A.1), `_AcceptMove`, `_NoteRejected`; reject log as M:2009-2025.
  `Home()`, `Slew()`, `Track()` decide first and write nothing on a rejection (M:2901-2911, 2943-2958, 2991-2996); the move edges of
  1b go through `_AcceptMove`. Until 3C.1, `replace` returns TRUE and the old preemption (`bRestartGoto`/`bRestartSlew`, precedence)
  acts. Delete `bCommandRefused`/`TCScommandRefusedEvent` (I:110, 2610-2614, 2644-2648). Internal requests set the latches directly.
- **Tests flipped:** none of the existing suites issues a move that the table rejects [verified by the command list of every test:
  all moves are sent after `rig.Online`, before any park/stop]. New suite: `Slew_While_Parked_Is_Rejected`, `Track_During_PowerOn_Is_Rejected`,
  `Home_While_Not_Ready_Is_Rejected` (D4), `Slew_During_Park_Is_Rejected`, `Goto_During_GoHome_Is_Rejected`, `Slew_During_Stop_Is_Rejected`
  (D5), `Rejected_Slew_Writes_No_Target`, `Rejection_Repeated_Within_2s_Is_Logged_Once` (`FB_RecordingComm`), `Park_Is_Never_Rejected`.
- **Acceptance:** CI green; the new suite pins every reject row of CA that IAG can reach.
- **Neutral?** No: D2-D5. Log text changes from "Slew refused: telescope not ready. ..." to "slew rejected: not ready" (anything that
  greps IAG logs for "refused" must change; none found in the IAG repo tools [unverified beyond `IAG/tools`]).
- **Risk:** medium-low. A rejection where IAG used to wait is the intended change; the risk is a client that sends `home` right after
  `power=1` and relied on the 2 min wait (now rejected `powering_on`). Check pyobs-brot's sequence in step 0.
- **Release:** IAG50cm minor.

**On-site check after step 2:**
- [ ] 1. `slew` while parked: rejected with the reason in the log, nothing moves, nothing pending after a later `power=1`
- [ ] 2. `home` right after `power=1`: rejected (`powering_on`); the power-on still ends at the home position by itself
- [ ] 3. `slew` during a park: rejected (`parking`), the park completes
- [ ] 4. `track` during a slew: accepted, the goto follows the slew (IAG precedence still, until 3C)
- [ ] 5. Normal use over a night with pyobs-brot driving

### Step 3A: abort stop and stop semantics (PR 4, five commits)

- **3A.1** Rename `bStopping` -> `bMoveAbortPending` (I:70, 492, 505, 558-565, 667, 694, 717, 724, 743, 751, 768, `tonParkPending`
  I:468, `_CommandState`); the error branch I:213-217 also clears it (M:604). Near-neutral (on an error the old flag dropped a few
  scans later at `bSettled`). Pin: *new* `Error_During_Abort_Stop_Clears_It`.
- **3A.2** `_StopTxRelease` (as M:2419-2441, IAG flavour): at the end of the body, `IF bSettled THEN bStopActive := FALSE; IF
  TCS_command = stop THEN bMoveAbortPending := FALSE`; replaces I:1007-1009 and the `bSettled` release of `bStopping` I:563-565.
  Flips: none expected (`Stop_Clears_The_Slew_And_Settles` asserts the settle). *New* `Stop_Is_Held_Until_The_Transaction_Settles`.
- **3A.3** The stop branch (I:502-541) clears goto, slew, gohome and track and interrupts all four stage machines (MC#84), not the
  first of an ELSIF chain; the park handling in that branch stays until 3B.1. *New* `Stop_Clears_Every_Pending_Move` (a goto and a
  queued home; both gone, both stages 0).
- **3A.4** Repeated stop: `Stop()` calls `fbStopTx.Restart()` and `fbFocus.Stop()` when `bStopActive` (M:2924-2931);
  `_SetStopTxInputs` (I:2227-2251) also fills `abMoving` (InMotion OR InRamp) and `abStopping`, which `Restart` needs
  (`FB_StopTransaction.TcPOU:117-133`) and IAG does not set today [verified]. *New* `Repeated_Stop_Restarts_Only_Moving_Axes`.
- **3A.5** Every preemption sets `bMoveAbortPending` (drop the "only if the preempted command is the dispatched one" condition,
  I:693-695, 716-718, 742-744). *New* `Park_Over_A_Waiting_Goto_Runs_A_Short_Abort_Stop` (stop dispatched, settles in about 3
  scans, then park).
- **Neutral?** No (D8-D11, D20). **Risk:** medium: stop timing on real NC (a settle that never comes holds `bStopActive` until the
  30 s forced release of IAG#120). **Release:** none on its own; released with 3B (one IAG50cm minor), or alone if 3B slips.

### Step 3B: park, power-on and reset precedence (PR 5, five commits)

- **3B.1** `bParkAfterStop` (D13): `Park()` queues during `bStopActive`; `Stop()` clears `bParkAfterStop` (MC#213); the stop branch
  always clears `bParkActive` (MONET); new private `_AutoStop()` used by every automatic stop (I:157-159, 352-354, 376-391, 409, 430):
  sets `bStopActive` and moves a pending `bParkActive` into `bParkAfterStop` (IAG#84, Q2); `_StopTxRelease` releases it at settle
  (M:2434-2438); `_CommandState.bParkPending` includes it. Replaces the conditions I:515-525. Pins: `IagParkInLimit_Tests` (both),
  `IagStopDuringPark_Tests` stay green; *new* `Park_During_Stop_Runs_After_Settle`, `Stop_Drops_A_Park_Queued_Behind_A_Stop`.
- **3B.2** Any stop aborts a power-on (D12): stop branch condition I:502 becomes `bStopActive`; `bPowerOnHold` I:359 drops
  `bUserStop`; `bUserStop` deleted. *New* `Automatic_Stop_In_A_Moving_PowerOn_Aborts_It`.
- **3B.3** Park beats power-on in every order (D14, D15): `Init()` refused while `bStopActive OR bParkActive OR bParkAfterStop`
  (`OR bSafeParked` per Q3) with the MONET log line (M:2684-2716, `power-on ignored: <reason>`); an accepted `Init()` clears the move
  latches; delete I:543-556 ("Init during a park cancels the park"); I:486 drops `AND TCS_command = poweron` so a park also aborts a
  requested power-on that has not been dispatched. *New* `Init_During_Park_Is_Refused`, `Init_During_Stop_Is_Refused`,
  `Park_Right_After_Init_Aborts_The_PowerOn`, `Init_Drops_A_Stale_Home`.
- **3B.4** Reset abort (D16, D17): split `_HandleReset` into the request part, run on every reset edge (method, input, cabinet key),
  and the hardware part, gated as today (I:183-196, safety acknowledge, dome reset, coordinates to park, `MarkAborted`; Q1). Request
  part as M:2088-2110: drop goto/slew/track/gohome, `bMoveAbortPending := BROTLib.F_ResetMoveAbort(bError, bParkRunning :=
  TCS_command = park, bAnyAxisMoving := OR over the two axes of enabled AND (InMotion OR InRamp OR Homing))`, clear
  `bSupersedeRequest` (after 3C.1), reset the stage machines. `bResetActive` stays a one-scan pulse (IAG resets the axes in its own
  passes, so MONET's hold M:989-997 is not needed) [design]. Flip: `IagResetUnderMotion_Tests.Reset_Without_An_Error_Is_Ignored` ->
  `Reset_Without_An_Error_Stops_The_Slew` (same Id): slew latch dropped, one stop per moving axis, no axis reset, no safety acknowledge,
  telescope stays online (READY_STATE 1.0 if Q1(b) is "no"). *New* `Reset_At_Rest_Drops_A_Pending_Move`, `Reset_During_Park_Keeps_The_Park`.
- **3B.5** Stuck-stop recovery by reset (D18, M:2062-2079): on the reset edge with `bStopActive OR bMoveAbortPending` and no enabled
  axis moving, `Reset()` each axis in Stopping and `fbStopTx.Cancel()`. *New* `Reset_Recovers_A_Stuck_Stop` (rig `SetStopWithoutDone`).
- **Neutral?** No. **Risk:** medium-high: reset now acts without an error (Q1), park/power precedence is a safety behaviour.
  **Release:** IAG50cm minor with 3A.

**On-site check after 3A+3B (IAG50cm):**
- [ ] 1. `stop=1` during a slew: one stop per moving axis, `bStopActive` falls only after both axes report Done and 3 scans at rest
- [ ] 2. `stop=1` three times within a few seconds during a slew and while idle: no hang, no second stop on a stopping axis
- [ ] 3. `park=1` during a running stop: the park starts after the stop has settled; `stop=1` before that settle cancels it
- [ ] 4. `park=1` right after `power=1` (before the covers move) and in the calibration sweep: startup aborted (READY_STATE -2), in-place park or park as IAG#197 decides; `power=1` during a park: rejected with "power-on ignored: park in progress"
- [ ] 5. `reset=1` during a slew, no error: the slew stops (abort stop), no axis is reset, no safety acknowledge, no NC error 0x4260
- [ ] 6. `reset=1` at rest with no error: nothing moves, the log shows nothing new apart from the reset; reset after an error as before (second pass about 2.5 s later)
- [ ] 7. Park in a limit (IAG#84): the mount homes out of the limit, then parks; a user `stop=1` during that home cancels both
- [ ] 8. Stuck stop: only if it happens by itself; provoking it needs an axis fault: only with Tim's agreement, otherwise mock only

### Step 3C: supersede and the arbiter (PR 6, two commits)

- **3C.1** Supersede (D6, D7): `_AcceptMove` `replace` sets `bSupersedeRequest`/`eSupersedeKeep`; the supersede block (M:678-708)
  runs before the arbitration; delete `bRestartGoto`/`bRestartSlew` (I:71-72, 745-768, 784-785, 2617, 2651) and the IAG#72 branch
  (I:720-724); error (I:213-217) and reset clear `bSupersedeRequest`. *New* `Slew_During_Goto_Replaces_It` (flip of I:734-744),
  `Track_During_Goto_Retargets` (IAG#41 pin), `Home_During_Track_Stops_Then_Homes` (IAG#72 pin). No existing IAG test exercises
  #41 or #72 [verified: test names and command lists above].
- **3C.2** Arbiter swap (D21): replace I:483-786 by `fbArbiter` wired as M:779-859 (`bParkWinsOverPowerOn := TRUE`, `bStop :=
  bStopActive`, `bStopped := bSettled`, `bEmergencyPark := FALSE`, idle drop of `MoveAxis`/`bTracking` as I:776-782, idle derived as
  M:794-795). Before the arbiter, the IAG park pre-step `_ParkPreStep()` [design]: if no stop, no abort stop and no power-on/startup
  is involved, it (a) runs the in-place park of I:567-652 and clears `bParkActive` (error, E-stop, axes off), (b) arms `ArmAll` and
  holds the park while not powered or `bParkForceInPlace` (I:654-656), (c) holds the park while `bGoHomeActive AND bLimitHome`
  (I:658-679), (d) holds it while not `bReady AND NOT bBusy` (the IAG dispatch gate; the arbiter alone would park at standstill
  without ready, A:140, which on IAG could drive uncalibrated axes after IAG#161). Held = `fbArbiter.bPark := bParkActive AND NOT
  bParkHeld`. After the arbiter, the post-hooks of the table in 3 (sweep stop, `bPowerParked`, stop-ignored log). The per-command
  timeout and `fbStopTx.Begin()` stay as I:788-797.
  Acceptance: **every suite green, no test edited in this commit.** A red test here is a gap in the pre-step, not a decision.
- **Neutral?** 3C.1 no; 3C.2 intended neutral after 3A/3B/3C.1. **Risk:** high (largest edit of the 3300-line block; the order in
  which interrupted stage machines are called changes to the arbiter's fixed order). **Release:** IAG50cm minor, full on-site check.

**On-site check after 3C (full, IAG50cm; IAG test plan `IAG/specs/plans/2026-10-09-iag50cm-telescope-test-plan.md` as base):**
- [ ] 1. Power-on from parked to READY_STATE 1.0; slew; `track` to a star; normal tracking over 30 min
- [ ] 2. `track` during a goto: abort stop, then the new target (IAG#41); `slew` during a goto: the slew wins
- [ ] 3. `home` while tracking: tracking stops, the mount homes (IAG#72)
- [ ] 4. `park` during a slew, during tracking, during the power-on sweep (IAG#197), with the axes off (in-place park, READY_STATE 0.3 then 0.0)
- [ ] 5. Repeat 3A+3B checks 1, 3, 5, 7
- [ ] 6. Horizon/pole limit while tracking (target that runs into the pole zone): automatic stop, limit home, no lost park
- [ ] 7. Emergency park by an axis error: only with Tim's agreement, otherwise mock only (`IagErrorPark_Tests`)
- [ ] 8. A night of normal use: no false timeouts 16#10/16#20/16#30/16#40, no unexpected rejections

Record per check: result (pass, fail, deviation), date and time, installed versions, log lines for anything unexpected. If a check
fails, roll back to the previous tag before the next session.

### Step 4 (checkpoint): template body in `FB_BaseTelescopeControl` (2026-10-21 plan step 5.4)

Not a code step of this plan; a go/no-go decision after 3C has run on site. **Go** only if all hold:
1. 3C has been on IAG50cm for at least one observing week with no rollback, and MONETcommon's rig suites and IAG's are green unedited.
2. A side-by-side of M's and I's bodies shows the same skeleton order (startup scan, clock, edges, reset, error ID, error reaction,
   targets, guards, acceptance gate, error park, supersede, arbiter, apply, dispatch, status, release, events) with every difference
   inside a hook from the table in 3 (`_ReadAxes`, `_ComputeTargets`, guards, park pre-step, post-hooks, stage machines).
3. No new policy input is needed beyond `bParkWinsOverPowerOn` and the pre-step/post-hook pair.
4. The ripple is accepted: BROTLib minor (breaking), HalfBROT re-pin and release (`FB_PendantControl` holds `REFERENCE TO
   FB_AltAzTelescopeControl`), MONETcommon minor, MONETS/MONETN re-pin, IAG50cm; on-site full checks on all three telescopes.
5. The estimate for 5.4 is below the cost of keeping two bodies in step (judged by Tim).

**No-go** = stop at the arbiter (the 2026-10-21 plan, decision 2, allows it). Either way, before 5.4: move `b*Active`, `b*Checked`,
`bMoveAbortPending`, `bParkAfterStop`, `bSupersedeRequest` into B in the same release that deletes them from M and I (name clash),
switch I to B's `bInterrupted` (B:67) and fix B's default methods that write the inputs (B:341-421).

## 6. Effort (PR-sized, no dates)

| Step | Size | CI runs (incl. expected re-runs) | Behaviour change | Release |
|---|---|---|---|---|
| 0 survey | S, no code | 0 | none | none |
| 1a + 1b latches and edges | M (about 150 edits in I, 58 test reads, 7 new tests) | 2-4 | ADS writers only | IAG50cm minor |
| 2 acceptance | M (3 methods, 4 method edits, 1 new suite of ~9 tests) | 2-3 | yes | IAG50cm minor |
| 3A abort stop / stop | M (5 commits, ~5 new tests) | 2-3 | yes | with 3B |
| 3B park / power / reset | M-L (5 commits, ~9 new tests, 1 flip) | 2-4 | yes | IAG50cm minor |
| 3C supersede + arbiter | L (pre-step, ~300 lines of I replaced, 3 new tests) | 3-5 | 3C.1 yes, 3C.2 no | IAG50cm minor |
| 4 checkpoint | S (decision); 5.4 itself XL, cross-repo | - | - | - |

About 22 new rig tests in total. Each rig test owns an `FB_IagRig` in `VAR_INST`, a full telescope with mocks; global data is about
32 MB today and BROTLibTests stopped starting at 44.8 MB (2026-10-21 plan, 5.1). The size per rig instance is [unverified]: read it
from the CI build output after step 1 and, if the step-3 total would pass about 40 MB, lower `MAXNUMBEROFTESTSFOREACHTESTSUITE` (32
today, largest suite has 10 tests) to 16, or chain several cases in one rig instance.

## 7. Release chain

No BROTLib change is needed for steps 1-3: `F_CommandAcceptance`, `ST_CommandState`, `E_CommandDecision`, `E_CommandRejectReason`,
`F_CommandRejectText`, `F_TCSCommandText`, `F_ResetMoveAbort`, `FB_CommandArbiter`, `FB_StopTransaction.Restart` are in BROTLib
`develop` [verified: `Telescope/` and `Telescope/Command/` listing]; that 0.19.0 (IAG's pin) contains all of them is [unverified]
(arbiter from 0.18.0 per the 2026-10-21 plan status). Optional BROTLib PR, comment only: A's header still calls FALSE "IAG50cm today"
(A:21-23). IAG50cm has no library workflow: `release.yml` bumps `ProjectVersion`, the merge to `main` is tagged; activation on the
PLC is Tim's. One IAG50cm release per step (1, 2, 3A+3B, 3C), so an on-site regression points at one step.

## 8. Risks and mitigations

- **Rig vs reality.** The mocks pin scan logic, not NC timing (StopDone skew, MC_Stop lock, sweep pauses IAG#198). The stop changes
  (3A) and the reset abort (3B.4) are where reality differs most. Mitigation: on-site lists per release, each test comment says
  "pinned by mock", reuse the measured stop model (BL#160 rig).
- **CI flakiness.** XAE hangs, runtime timeouts, COM start failures (four in IAG#215). Mitigation: re-run before reading a red run,
  keep PRs small, never mix a behaviour flip with a rename in one commit, so a red run after a rename points at the rename.
- **The 3300-line block.** Renames through ~150 sites and the 3C.2 swap can hide a missed read. Mitigation: scripted rename + diff
  review, grep acceptance in 1a/1b, "no test edited" acceptance in 3C.2.
- **Comm-layer and ADS writers.** Step 0; an unknown writer on the control PC is the main residual risk of step 1.
- **Name collisions.** New names in I must not exist in B or `FB_RaDecTelescopeControl` [verified: none of `b*Active`,
  `bMoveAbortPending`, `bParkAfterStop`, `bSupersedeRequest`, `fbArbiter` is declared there]. B's `bInterrupted` vs I's
  `bInterupted` (step 4). MONETcommon still compiles a local `F_CommandAcceptance`; IAG must call the BROTLib units qualified
  (`BROTLib.F_CommandAcceptance`, as I already does for `BROTLib.F_ErrorParkRequest` I:231).
- **Release churn.** Four IAG50cm releases, each with a visit. Mitigation: 3A and 3B share one release; step 1 can go with step 2 if
  step 0 finds no writer and Tim prefers fewer visits.
- **Behaviour the operators rely on.** Rejections instead of waits (step 2), reset acting without an error (3B.4), `power=1` refused
  during a park (3B.3). Mitigation: release notes in the IAG50cm PR with the new log lines; the IAG runbooks updated in step 0.
- **TcUnit limits.** 18 of 32 suites after step 2; data size above.

## 9. Open questions for Tim

1. **Q1 Reset without an error: how much of it acts?** (a) drop moves and abort-stop a running move: decided (MONET). (b) also abort a
   running power-on and mark the startup aborted (MONET: `MarkAborted` M:2082, `_PowerOn` guard M:1377)? (c) also request the safety
   acknowledge and run the axis reset passes (IAG today only with an error or a pending acknowledge, IAG#36/#59)?
   **Recommendation:** (b) yes, as MONET; (c) no, keep it gated: it pulses the safety relay for nothing.
   **Decided (Tim, 2026-11-09): recommendation taken.** (b) yes, a reset without an error also aborts a running power-on; (c) no, the safety acknowledge and axis reset passes stay gated.
2. **Q2 A pending park and an automatic limit stop.** MONET drops a pending park when its horizon guard stops (stop branch, A:84-102);
   IAG keeps it and homes out of the limit first (IAG#84). **Recommendation:** keep IAG's (park is the safe direction; via
   `bParkAfterStop`, 3B.1), and propose it to MONET later.
   **Decided (Tim, 2026-11-09): recommendation taken.** Keep IAG's rule (IAG#84); propose it to MONET later.
3. **Q3 `power=1` during the in-place park** (`bSafeParked`, up to 120 s, `stop` is ignored there, IAG#196). Today the power-on ends
   it (IAG#110). **Recommendation:** refuse it like a park in progress, reason "in-place park in progress, ends within 120 s".
   **Decided (Tim, 2026-11-09): recommendation taken.** Refuse `power=1` during the in-place park, reason "in-place park in progress, ends within 120 s".
4. **Q4 Release cadence.** One release per step (1, 2, 3A+3B, 3C) with a visit each, or 1+2 together. **Recommendation:** per step;
   step 1 only gets the short smoke check.
   **Decided (Tim, 2026-11-09): recommendation taken.** One release per step.
5. **Q5 Stuck-stop recovery by reset (3B.5)** resets an axis that hangs in Stopping at rest; IAG has the 30 s forced release
   (IAG#120). **Recommendation:** add it (MONET rule, faster exit), mock-tested; no provoked on-site check.
   **Decided (Tim, 2026-11-09): recommendation taken.** Add stuck-stop recovery by reset (3B.5), mock-tested.

## 10. Not verified

- Nothing in this plan has been compiled or run; every [design] item (pre-step, post-hooks, `_AutoStop`, reset split) is untested.
- Writers outside the repos (control PC scripts, watch lists, BROTweb deployment for IAG), see step 0.
- Whether `FB_StartupControl.MarkAborted` on a completed startup changes READY_STATE (`FB_StartupReadiness` not read), relevant to
  Q1(b) and to the flipped reset test.
- That the 0.19.0 release holds every BROTLib unit used here; the global data size per rig instance.
- That no existing suite flips in steps 2 and 3C.2 is a reading of the test command lists, not a run.
