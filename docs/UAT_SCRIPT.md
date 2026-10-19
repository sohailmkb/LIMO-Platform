# UAT script for ChatGPT (agent mode)

How to use: in Lovable press Publish, then Update, so the live site has the latest build. Open ChatGPT, switch on agent mode, and paste everything in the "Prompt" block. When it asks you to sign in or to open an email, take over, do it, and hand back. When it finishes, paste its report to Claude.

---

## Prompt

```
You are a meticulous QA tester. Test the web app at https://velvet-ride-reservations.lovable.app , a chauffeur and limousine booking platform. Follow the test cases below in order. Do not skip any. Do not change company settings unless a test says so.

Rules
- Never type passwords. When a test needs a signed-in account, stop and ask me to sign in, then continue.
- When a test needs an email link, ask me to open it, or use the "Copy link" option the app offers.
- Test data: use names starting with "UAT" so they are easy to find later. Use pickup dates at least 3 days in the future unless the test says otherwise.
- Use a desktop-width window. For tests marked [PHONE], resize the window to about 390 px wide.
- After each test, record: ID, result (PASS, FAIL or BLOCKED), what you saw if it differs from Expected, and the exact error text if any. Take a screenshot for every FAIL.
- At the end, output ONE markdown table with columns: ID | Result | Actual (only if not PASS) | Severity (Blocker, Major, Minor, Cosmetic). Then a short list "Top 5 problems".

Accounts (I sign in for you)
- OWNER: sohailmkb@gmail.com, owner of the company "Demo Limo Toronto" (slug demo-toronto).
- PLATFORM: sohailmkb+admin@gmail.com, platform owner.
- New people are invited during the tests to sohailmkb+dispatch@gmail.com, sohailmkb+accounts@gmail.com, sohailmkb+client@gmail.com and sohailmkb+rider@gmail.com. All arrive in the same Gmail inbox.

A. Look and feel
A1 Open /login. Expected: split screen, dark left panel with "Every journey, impeccably run.", form on the right, EN and FR switch works.
A2 [PHONE] Open /login. Expected: only the form with the brand mark on top, nothing cut off, no sideways scrolling.
A3 Open /book/demo-toronto. Expected: dark header band with the company name in a serif font, form card overlapping it, 4 steps.

B. Public booking (signed out)
B1 On /book/demo-toronto type "Pearson" in Pickup. Expected: "Toronto Pearson International Airport (YYZ)" is the first suggestion and marked as an airport; picking it shows flight number and meet and greet fields.
B2 Type "100 King Street West Toronto" in Drop-off and pick a suggestion. Expected: distance fills in by itself, "About N min drive" appears, a small map draws the route.
B3 Choose Round trip, set a return time after pickup, add 1 stop. Expected: price updates and shows Fare and Return fare lines.
B4 Vehicle step. Expected: class cards show seats, luggage, and a price; selecting one highlights it.
B5 Details step: name "UAT Rider", email sohailmkb+rider@gmail.com, phone. Gratuity 15%. Expected: Gratuity line appears in the price.
B6 Submit. Expected: status page with a reference code, "Your request is with Demo Limo Toronto", the full price breakdown matching the review step to the cent. Note the URL.
B7 [PHONE] Repeat B1 to B4 at phone width. Expected: everything usable, nothing overlaps.

C. Staff basics (sign in as OWNER)
C1 After sign-in. Expected: lands on Today (or a portal chooser), onyx sidebar, serif page titles.
C2 Bookings list. Expected: the UAT Rider request from B6 is there as a quote.
C3 Open it. Expected: two trip cards (Outbound, Return), the stop shows on the outbound timeline, flight and meet and greet shown if set.
C4 Click "Send quote". Expected: toast "Quote link copied. Valid until ...".
C5 Open the copied link in a private window. Expected: "Accept and confirm" button; click it. Expected: status becomes confirmed.
C6 Back on staff side refresh the booking. Expected: Confirmed. Assign driver "Demo Driver" to the outbound leg only. Expected: each leg has its own driver.
C7 New booking (staff): one way, Pearson to Union Station, Sedan, 2 passengers, child seat extra if offered, promo code SAVE10 if it exists. Expected: price breakdown updates live; "Create booking" works and opens the booking.
C8 Edit that booking and change vehicle class to SUV. Expected: toast "Price changed from X to Y" with real amounts.
C9 Duplicate it for one hour later. Expected: new booking opens with the same details.
C10 Assign Demo Driver to both C7 and C9. Expected: on the second, an amber warning "Already busy at that time with #N".
C11 Cancel C9 with reason "UAT test". Expected: cancelled, reason shown, balance due 0, no payment buttons.
C12 Invoice for C7. Expected: printable invoice with company name, lines, tax, total; Print opens the print dialog with only the invoice.
C13 Dispatch: switch to Week view and filter by driver. Expected: trips shown in the right days; filter works.
C14 Reports: Revenue, Driver earnings, Ride log tabs; "Accounting export" downloads a CSV. Expected: CSV has Date, Invoice No, Customer, Customer Email, Description, Amount, Tax, Total, Currency, Status.
C15 Bookings, Import: download the template, upload it unchanged. Expected: 2 rows ready; import creates 2 bookings.
C16 Settings: Booking widget shows an iframe snippet with Copy. Open /book/demo-toronto?embed=1. Expected: only the form, no header or footer.
C17 Pricing: rate cards show Per extra stop and Minimum hours; Extras and Promo codes sections exist; add an extra "UAT Water" 5.00.
C18 Settings, Brand: upload a small logo. Expected: appears in the sidebar badge, on /book/demo-toronto and on an invoice.
C19 Switch to French. Expected: no English left on Bookings, a booking page and Settings; times use 24 hour format.

D. People and access (signed in as OWNER)
D1 People and access: invite sohailmkb+dispatch@gmail.com as Dispatcher. Expected: a copyable invite link, or "now has access".
D2 Invite sohailmkb+accounts@gmail.com as Accountant.
D3 Customers, Client companies: create "UAT Corp" with auto-confirm off. Invite sohailmkb+client@gmail.com as Client admin of UAT Corp.
D4 Open the dispatcher invite link in a private window; ask me to create the password and confirm the email. Expected: lands in the Demo Limo Toronto console.
D5 As dispatcher: Expected no Pricing, Settings or People and access in the menu; opening /pricing directly shows "You do not have access to this page".
D6 Accept the accountant invite (ask me). Expected: Reports and bookings visible, no edit, assign or cancel buttons.
D7 Accept the client invite (ask me). Expected: My trips with "UAT Corp" header and "Book a ride". Book a ride. Expected: it appears in My trips; on the OWNER side it is a quote on the UAT Corp account.
D8 As OWNER try to pause or remove yourself. Expected: not allowed. Pause the dispatcher. Expected: dispatcher loses access on next page load. Resume.
D9 Invitations tab: revoke an unused invite. Expected: its link shows "revoked".

E. Platform console (ask me to sign in as PLATFORM)
E1 Expected: platform console opens (companies, users, plans, reference, audit).
E2 Users and access: search "sohailmkb". Expected: each account with its access chips (company and role).
E3 Suspend sohailmkb+dispatch@gmail.com with reason "UAT". Then (ask me) sign in as that user. Expected: "Your access is paused" page. Restore afterwards.
E4 Companies: open Demo Limo Toronto. Expected: details, team, plan and status.

F. Customer self-service
F1 On the B6 status page click "See all your trips", enter sohailmkb+rider@gmail.com, ask me to open the email link. Expected: My trips lists the UAT Rider booking with Receipt; Receipt shows the invoice layout.

G. General
G1 For every page visited, note anything broken: layout overlap, text cut off, untranslated text, wrong currency or time zone (company is in Toronto, CAD), spinners that never stop, error toasts.
G2 Note anything that feels slow (more than 3 seconds) or confusing, with the page name.
```

---

## After the run

Paste ChatGPT's table to Claude. Claude fixes code issues directly in GitHub (no Lovable credits) and writes a short Lovable prompt only for larger screen changes.
