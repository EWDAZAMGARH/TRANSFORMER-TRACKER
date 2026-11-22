/*
 TF-Tracker : SIR photos and PDFs in YOUR Google Drive  (Google Apps Script web app)
 The app sends each SIR photo and each SIR PDF to this script. The script saves the file in YOUR Drive folder
 and gives the link back. Only the link is kept in the app (Supabase), so the database does not fill up.

 SETUP (once, by the Admin):
   1) Google Drive: make a folder (for example "SIR Photos and PDFs"). Open it. The web address ends with  /folders/XXXXXXXX  - that XXXXXXXX is the FOLDER ID.
   2) script.google.com > New project > delete the sample code > paste this whole file > Save.
   3) In the toolbar choose the function  authorizeOnce  and press Run. Click Review permissions > your account > Advanced > Go to ... > Allow.
   4) Deploy > New deployment > type: Web app > Execute as: Me > Who has access: Anyone > Deploy.
   5) Copy the "Web app" link (ends with /exec). Open it once in a browser tab: it must show  {"ok":true,"msg":"TF-Tracker SIR Drive is running"}.
   6) In the app: Admin tab > SIR form > paste the link and the FOLDER ID > Save > Test.
 After you change this code, use Deploy > Manage deployments > Edit > Version: New version > Deploy (the link stays the same).

 Files are saved with "anyone with the link can view" so every employee can open the photo / PDF from the app.
*/
var MAX_BYTES = 3 * 1024 * 1024;           // one file at most 3 MB
var OK_TYPES = { 'image/jpeg': 1, 'image/png': 1, 'application/pdf': 1 };

function out_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
function reply_(o, id) {                    // the app posts a hidden form and reads the answer through postMessage (no CORS problem)
  var j = JSON.stringify(o).replace(/</g, '\\u003c'), i = JSON.stringify(String(id || '')).replace(/</g, '\\u003c');
  return HtmlService.createHtmlOutput('<script>var r=' + j + ';r.id=' + i + ';window.top.postMessage(r,"*");</script>OK').setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);
}
function authorizeOnce() {                  // run this ONCE in the editor so Google asks for your permission
  DriveApp.getRootFolder();
  return 'OK';
}
function doGet() { return out_({ ok: true, msg: 'TF-Tracker SIR Drive is running' }); }

function idOf_(u) { var m = String(u || '').match(/[-\w]{25,}/); return m ? m[0] : ''; }
function folder_(id) { if (!/^[A-Za-z0-9_-]{10,100}$/.test(String(id || ''))) throw new Error('Wrong folder ID.'); return DriveApp.getFolderById(id); }

function doPost(e) {
  var id = '', out = function (o) { return id ? reply_(o, id) : out_(o); };
  try {
    var raw = (e && e.parameter && e.parameter.payload) || (e && e.postData && e.postData.contents), b = JSON.parse(raw);
    id = (b && b.id) ? String(b.id) : '';
    if (!b) return out({ ok: false, error: 'Empty request.' });
    if (b.ping) { var f0 = folder_(b.folder); return out({ ok: true, ping: true, folder: f0.getName() }); }
    var folder = folder_(b.folder);
    if (b.action === 'put') {
      var type = String(b.mime || '');
      if (!OK_TYPES[type]) return out({ ok: false, error: 'Only JPG, PNG or PDF files are allowed.' });
      var bytes = Utilities.base64Decode(String(b.b64 || ''));
      if (!bytes.length || bytes.length > MAX_BYTES) return out({ ok: false, error: 'The file is empty or larger than 3 MB.' });
      var name = String(b.name || 'file').replace(/[^\w.\-]+/g, '_').slice(0, 80);
      var file = folder.createFile(Utilities.newBlob(bytes, type, name));
      file.setSharing(DriveApp.Access.ANYONE_WITH_LINK, DriveApp.Permission.VIEW);
      return out({ ok: true, url: file.getUrl(), id: file.getId() });
    }
    if (b.action === 'get') {               // give the photo back (used when the Admin edits a SIR and the PDF is made again)
      var fid = idOf_(b.url || b.fid), file2 = DriveApp.getFileById(fid), inside = false, ps = file2.getParents();
      while (ps.hasNext()) { if (ps.next().getId() === folder.getId()) inside = true; }
      if (!inside) return out({ ok: false, error: 'This file is not in your SIR folder.' });
      var blob = file2.getBlob(), by = blob.getBytes();
      if (by.length > 1024 * 1024) return out({ ok: false, error: 'The photo is too large to read back.' });
      return out({ ok: true, mime: blob.getContentType(), b64: Utilities.base64Encode(by) });
    }
    return out({ ok: false, error: 'Unknown request.' });
  } catch (err) {
    return out({ ok: false, error: String(err && err.message || err) });
  }
}
