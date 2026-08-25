import Foundation

// Le code au niveau supérieur est isolé sur l'acteur principal : la fonction d'assertion
// doit l'être aussi pour pouvoir écrire dans `ok`.
var ok = true
@MainActor func check(_ label: String, _ condition: Bool) {
    print(condition ? "  ✓ \(label)" : "  ✗ \(label)"); if !condition { ok = false }
}
@MainActor func finish() {
    print(ok ? "\nOK" : "\nÉCHEC")
    if !ok { exit(1) }
}

// Lecture d'une archive bureautique : la structure ZIP, le XML, les entités, les blancs.
// La pièce d'essai est un vrai .docx, rangé sans compression pour que la décompression
// — absente hors Apple — ne soit pas nécessaire ici.

print("Archive ZIP et XML bureautique :")

let fixture = URL(fileURLWithPath: "Tools/tests/fixtures/exemple.docx")
guard let data = try? Data(contentsOf: fixture) else {
    print("  ✗ pièce d'essai introuvable")
    exit(1)
}

check("l'archive s'ouvre", Zip(data) != nil)
check("le catalogue liste les pièces", Zip(data)?.names.contains("word/document.xml") == true)

let text = DocumentText.extract(from: data, name: "exemple.docx")
check("le texte est extrait", text != nil)

let body = text ?? ""
check("les accents survivent", body.contains("préavis") && body.contains("recommandée"))
check("les entités numériques sont décodées", !body.contains("&#233;"))
check("l'esperluette est décodée en dernier", body.contains("recommandée & avec"))
check("aucune balise ne subsiste", !body.contains("<w:") && !body.contains(">"))
check("les paragraphes deviennent des lignes",
      body.components(separatedBy: "\n").filter { !$0.isEmpty }.count >= 5)
check("deux passages d'un même paragraphe restent sur la même ligne",
      body.contains("trois mois. Il est ramené"))

print("\nCe qui ne doit pas passer :")
check("un fichier qui n'est pas une archive est refusé",
      DocumentText.extract(from: Data("bonjour".utf8), name: "faux.docx") == nil)
check("une extraction trop maigre est écartée",
      DocumentText.extract(from: Data("court".utf8), name: "note.doc") == nil)
check("une extension inconnue n'est pas traitée",
      DocumentText.extract(from: data, name: "exemple.zip") == nil)

print("\nNettoyage du texte :")
check("les blancs multiples se resserrent",
      DocumentText.tidy("un    deux\t\ttrois") == "un deux trois")
check("les lignes vides consécutives se réduisent à une",
      DocumentText.tidy("a\n\n\n\nb") == "a\n\nb")
check("les entités nommées sont décodées",
      DocumentText.decodeEntities("&lt;a&gt; &amp; &quot;b&quot;") == "<a> & \"b\"")
check("une entité doublement échappée reste littérale",
      DocumentText.decodeEntities("&amp;lt;") == "&lt;")

finish()
