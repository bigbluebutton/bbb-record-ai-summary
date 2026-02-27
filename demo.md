For our demo, we tweaked Docs and B3desk to be able to achieve the expected result.

## Using Keycloak Service Account Roles to Update Docs

For the demo, we used **Service Account Roles** in Keycloak to allow updates to Docs.

Important behavior:
- The **parent document** must allow **Editing**  in Sharing settings
- Once enabled, the **service account** can create a **child document** under that parent
<img width="400" src="https://github.com/user-attachments/assets/3d3d8409-bf04-4637-9230-ec4aa2c94c94" />

---

## Keycloak Configuration

1. Select the correct **Realm**  
   Example: `docs`

2. Open the menu **Clients**

3. Select the **Docs client**

4. Scroll to **Capability config**

5. Under **Authentication flow**, enable:
   - `Service accounts roles`
     
<img width="400" src="https://github.com/user-attachments/assets/a6f8e244-c714-4873-9039-9f5d74f59c15" />

---

## Credentials

1. Open the **Credentials** tab
2. Copy the **Client Secret**
3. The **Client ID** is the client name itself

<img width="400" src="https://github.com/user-attachments/assets/7cb3ba00-16a6-410c-8dfc-750a81062b7e" />


You should now have:

```bash
REALM="docs"
CLIENT_ID="docs"
CLIENT_SECRET="docs_client_secret_123"
```

That will be used to config the `bbb-record-ai-summary`.

---

## b3desk Integration

For b3desk, we added two new parameters to the /create request:

- `sharedNotesInitialContentJsonUrl`
URL pointing to a BlockNote JSON content (to be used as initial content of Shared Notes)

- `meta_bbb-docs-document-id`
ID of an existing Docs document (with sharing settings enabled and `editing` allowed)

With these parameters, the service automatically creates a sub-document under the given Docs document containing the meeting summary.

<img width="400" src="https://github.com/user-attachments/assets/b66ccb3e-9376-47e1-a364-72c8ec53fbe0" />
