Et pour le bug de l'adresse, merci Do(w)n Jones, l'exemple était parfait 🔍

Le souci : la recherche ne passait que par OpenStreetMap, où il manque plein de numéros de maison en France. Donc pour « 9 rue Vital Lauba », seule la rue était connue, et en prime il te sortait un faux « 9 rue » en Lozère 🙃

C'est corrigé :
• la recherche interroge aussi la **Base Adresse Nationale** (l'annuaire officiel des adresses françaises) : « 9 rue vital lauba 33160 » tombe pile sur le n°9 à Saint-Médard-en-Jalles ;
• quand tu tapes une adresse, les adresses officielles passent en premier ; pour un col, une ville ou un lieu, rien ne change ;
• si tu mets un code postal, les résultats d'ailleurs sont écartés : fini la Lozère.

Ce sera dans la prochaine version avec le reste. Si tu tombes encore sur une adresse introuvable, envoie-la, c'est super utile 🙏
