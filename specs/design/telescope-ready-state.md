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
over completion; loss of operational readiness invalidates earlier success.

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
