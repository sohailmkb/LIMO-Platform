# Maps setup (address search and driving distance)

About 10 minutes. The key stays on the server; browsers never see it.

## 1. Google Cloud key
1. Go to console.cloud.google.com, create a project (for example "Limo Platform") and attach a billing account. Google gives a monthly free usage allowance; check current Maps Platform pricing before launch.
2. APIs and Services, Library: enable **Places API (New)** and **Routes API**.
3. APIs and Services, Credentials, Create credentials, API key.
4. Edit the key: under API restrictions choose "Restrict key" and tick only Places API (New) and Routes API. Leave application restrictions as None (the key is only used from the Supabase server).
5. Copy the key. Do not paste it into chat, Lovable or the code.

## 2. Supabase
1. Project Settings, Edge Functions, Secrets: add `GOOGLE_MAPS_API_KEY` with the key.
2. Make sure `APP_ORIGINS` lists every site that may use maps, comma separated, for example:
   `https://id-preview--9ffac9da-f0de-4950-806e-56cf589a38cf.lovable.app,https://your-live-domain.com`
3. Deploy the function from the repo folder: `npx supabase functions deploy maps --project-ref jtfdgxiiwysxdjhxymmm`

## 3. Check
On the booking page, type "Pearson" in Pickup. Suggestions should appear, and after choosing pickup and drop-off the distance fills in by itself.
If nothing appears, the fields still work as plain text. Send Claude the error from Supabase, Edge Functions, maps, Logs.
