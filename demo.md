For our demo, we tweaked Docs and B3desk to be able to achieve the expected result.

## Using Keycloak Service Account Roles to Update Docs

For the demo, we used **Service Account Roles** in Keycloak to allow updates to Docs.

Important behavior:
- The **parent document** must allow **Editing**  in Sharing settings
- Once enabled, the **service account** can create a **child document** under that parent

---

## Keycloak Configuration

1. Select the correct **Realm**  
   Example: `docs`

2. Open the menu **Clients**

3. Select the **Docs client**

4. Scroll to **Capability config**

5. Under **Authentication flow**, enable:
   - `Service accounts roles`

---

## Credentials

1. Open the **Credentials** tab
2. Copy the **Client Secret**
3. The **Client ID** is the client name itself

You should now have:

```bash
REALM="docs"
CLIENT_ID="docs"
CLIENT_SECRET="docs_client_secret_123"
```

---

## b3desk Integration

For b3desk, we added two new parameters to the /create request:

- `sharedNotesInitialContentJsonUrl`
URL pointing to a BlockNote JSON content (to be used as initial content of Shared Notes)

- `meta_bbb-docs-document-id`
ID of an existing Docs document (with sharing settings enabled and `editing` allowed)

With these parameters, the service automatically creates a sub-document under the given Docs document containing the meeting summary.
