# Telescope READY_STATE

The existing numeric field is authoritative for completed startup across MONET/N, MONET/S, and IAG50.

| Value | Meaning |
|---|---|
| -1 | Error |
| 0 | Parked |
| 0.3 | Parking |
| 0.7 | Initializing/preparation |
| 0.8 | Calibrating, including automatic startup positioning |
| 1 | Online: startup complete and operational |
| -2 | Existing unknown/not operational state, including an aborted partial startup |

`FB_StartupReadiness` holds the public state independently of mechanical readiness.
Controllers feed per-scan Start, Calibrating, Completed and Aborted events plus current
error/park/operational inputs. Clear event inputs each scan. Completed is asserted only
at the final controller stage after every startup-owned action finishes. A power-to-home
handoff, stopped sample or cleared command flag is not completion. Abort/error/park wins
over completion. A transient loss of Operational gates online (-2) without erasing
completed startup; recovery restores 1 without repeating calibration. A new Start,
explicit Aborted, Error, Parked or Parking still invalidates earlier completion.

Controllers do not drive `FB_StartupReadiness` directly. `FB_StartupControl` wraps it and owns the
glue that both concrete controllers need: per-scan events (`BeginScan`, `Mark*`, `Update`), dropping a
repeated power request on an online telescope, the `Init()` gate (`AcceptInit`: refused while a startup
runs, after it completed, also across a transient interlock, and while automatic mode is suspended),
`EnterSuspend`/`Suspend` for a disabled automatic mode, and `PublishDue` for the READY_STATE publish
decision. It has no motion dependency and is covered by `FB_StartupControl_Tests`.

Keep mechanical bReady available internally during calibration/home. No transient 1 is
allowed between startup stages. Normal subsequent slew/tracking remains online. The
common block has no motion dependency and can be tested without NC hardware. Concrete
controllers must still test that their terminal event matches physical completion.

Publish the existing field on changes and periodically at rest, without a new MQTT topic
or request protocol. Consumers must still apply their telemetry-health checks; retained
or disconnected cached state is not proof of current readiness. STATUS.GLOBAL is unchanged.

Coordinate pybrotlib CALIBRATING mapping and pyobs readiness handling before deploying
controllers that publish 0.8. Validate MONET/N and MONET/S separately, plus IAG50.
Related: https://github.com/BROTLib/BROTLib/issues/68.
