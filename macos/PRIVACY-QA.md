# Privacy-first macOS verification contract

Scope fixed before implementation: macOS only. Android remains upstream and is not recommended by this fork. Users record a chosen window locally and inspect/delete its screenshot and OCR. No keyboard recording. No unrequested introduction/tutorial text in the application.

Required: (1) no key monitoring/Accessibility permission; (2) launch stopped, login default off; (3) pause invalidates in-flight work; (4) shared image/OCR expiry and delete-all; (5) system picker restricted to one window, no full display fallback; (6) private storage permissions.

Scenarios (start / input / action / expected):
1. Fresh launch / no target / open app / stopped, zero records, start unavailable with target state.
2. Stopped / synthetic fixture window / select, start, wait / only fixture screenshot and matching OCR persist; stop freezes count.
3. Recording / pending capture / pause or change target or delete / pending result cannot persist.
4. Saved record / restart / reopen / screenshot and OCR persist, recording stays stopped, target must be selected again.
5. Records / delete confirmation / cancel then confirm / cancel preserves, confirm removes images and OCR and cannot be undone by pending work.
6. Saved records older than retention / shorter retention / apply / both image and OCR expire; 0/1/100 records covered by storage tests.
7. Stopped / picker cancel or capture/store failure / retry / no unintended recording, clear error, safe retry.
8. Login off / on then off / toggle / actual ServiceManagement state reflected; keep off after QA.

Design: native macOS single window, white background, dark text, blue primary action; primary status 24pt, body 16pt, secondary 13pt; 8/16/24pt spacing; native rounded controls; record screenshot contained without cropping, selectable OCR below. No illustrations. Compare all six characteristics to the rendered app.

Native adaptation: macOS desktop only, sizes 640x760 and 1000x900 points (no mobile widths or touch requirement); keyboard navigation and >=44pt primary control heights replace touch testing. No network integration is specified; A3 checks actual local capture/OCR/storage. C2 checks rejected unsafe/malformed storage, invalid target and unsupported retention instead of form fields. D2 measure local control responses three times; OCR completion max 30 seconds with immediate progress and timeout. E2 contrast measured for custom colors; native system focus inspected. No safety grade without evidence. 20 items are 5 or 0, target >=90, each category >=15; unverified is 0. If OS permissions block capture, report verification pending.
