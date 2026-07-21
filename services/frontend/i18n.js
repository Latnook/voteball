const LANG_STORAGE_KEY = 'voteballLang';

const DICTIONARY = {
  en: {
    voteEyebrow: 'LIVE POLL',
    voteHeroTitle: 'Pick your side',
    voteIntro: 'Football fandom vs. how you vote — anonymous, one vote per browser.',
    voteLegendLeague: 'League & clubs',
    voteLeagueHint: "Pick up to 3 clubs per league — or just the league if you don't follow a specific club. Not limited to one league.",
    voteClubPlaceholderOption: '— just the league —',
    votePicksSummaryLabel: 'Your picks so far:',
    votePicksSummaryEmpty: 'No teams picked yet.',
    voteLegendPrevious: '2. Current Knesset — who did you vote for?',
    voteDidNotVote: "Didn't vote / not eligible",
    voteLegendUpcoming: 'Upcoming election — who are you considering?',
    voteUpcomingHint: 'Choose up to 3.',
    voteUndecided: 'Undecided / prefer not to say',
    voteReview: 'Review your ballot',
    voteErrorLoadForm: "Couldn't load the form — try refreshing.",
    voteErrorRequiredFields: 'Please fill in all required fields.',
    voteErrorPickParty: "Pick at least one party you're considering, or mark yourself undecided.",
    voteErrorSubmit: 'Something went wrong submitting your vote.',
    voteAlreadyVoted: 'This browser has already voted — one ballot per visitor, so this one was not counted. Use the Results link above to see the standings.',
    voteReviewHeading: 'Review your ballot',
    voteReviewTeams: 'Teams',
    voteReviewPrevious: 'Previous vote',
    voteReviewUpcoming: 'Upcoming picks',
    voteEdit: 'Edit',
    voteConfirmSubmit: 'Confirm & submit',

    navResults: 'Results',
    navVote: 'Vote',

    resultsTitle: 'Voteball — Results',
    resultsHeading: 'Voteball — Results',
    resultsEyebrow: 'LIVE RESULTS',
    resultsIntro: 'Anonymous, aggregate results from every Voteball ballot so far.',
    resultsModeClubLeague: 'Start from a club/league',
    resultsModeParty: 'Start from a party',
    resultsLabelLeague: 'League:',
    resultsLabelClub: 'Club (optional):',
    resultsClubPlaceholderOption: '— whole league —',
    resultsLabelPartyType: 'Party type:',
    resultsPartyTypePrevious: 'Previous (current Knesset)',
    resultsPartyTypeUpcoming: 'Upcoming election',
    resultsLabelParty: 'Party:',
    resultsHeadingPrevious: 'Previous Knesset vote breakdown',
    resultsHeadingUpcoming: 'Upcoming election breakdown',
    resultsDidNotVote: 'Did not vote',
    resultsUndecided: 'Undecided',
    resultsLeagueWideSuffix: ' (league-wide)',
    resultsErrorLoad: "Couldn't load results — try refreshing.",
    resultsNationalHeading: 'National standings',
    resultsExplorerHeading: 'Explore the results',
    resultsNoData: 'No votes yet for this selection.',
    resultsScopeNational: 'all',
    resultsYouBadge: 'YOU',
    resultsYourLineup: 'Your line-up',
    resultsScoreLabelTeam: 'Team',
    resultsScoreLabelPrevious: 'Last time',
    resultsScoreLabelUpcoming: 'Considering',
    resultsFanLeanHeading: 'How fans of {who} lean',
    resultsFanLeanNoteClub: 'Upcoming-election picks among {club} supporters.',
    resultsFanLeanNoteLeague: 'Upcoming-election picks among {league} followers.',
    resultsMigrationHeading: 'Where your camp is headed',
    resultsMigrationNote: 'Among {scope} voters who picked {party} last time, here is what they are considering now.',
    resultsMigrationNoteDidNotVote: "You told us you didn't vote last time, so there's no migration to show.",

    analyticsHeading: 'Fan Politics',
    analyticsTabDiversity: 'Diversity',
    analyticsTabLean: 'Political Lean',
    analyticsTabSwitching: 'Switching',
    analyticsErrorLoad: "Couldn't load this — try refreshing.",
    analyticsSpotlight: 'Spotlight',
    analyticsFullRanking: 'Full Ranking',
    analyticsIncludeWorldCup: 'Include World Cup national teams',
    analyticsMostMixed: 'Most Mixed Fanbases',
    analyticsMostOneSided: 'Most One-Sided Fanbases',
    analyticsEffectiveParties: '{n} effective parties',
    analyticsTooFewVotes: 'Not enough votes yet for a meaningful diversity score.',
    analyticsAxisLeft: 'Left',
    analyticsAxisRight: 'Right',
    analyticsNoStatedPosition: 'No stated position',
    analyticsSecurityLabel: 'Security:',
    analyticsReligiosityLabel: 'Religion & state:',
    analyticsBlocLabel: 'Bloc:',
    analyticsSectorLabel: 'Sector:',
    analyticsBlocBibi: 'Bibi bloc',
    analyticsBlocOpposition: 'Opposition',
    analyticsBlocUnaligned: 'Unaligned',
    analyticsSectorSecular: 'Secular',
    analyticsSectorTraditional: 'Traditional',
    analyticsSectorReligiousZionist: 'Religious Zionist',
    analyticsSectorHaredi: 'Haredi',
    analyticsSectorArab: 'Arab',
    analyticsSecurityDovish: 'Dovish',
    analyticsSecurityHawkish: 'Hawkish',
    analyticsReligiositySeparationist: 'Separationist',
    analyticsReligiosityClerical: 'Clerical',
    analyticsNational: 'National',
    analyticsPickClub: 'Jump to a club:',
    analyticsScopeLabel: 'Scope:',
    analyticsStatusStayed: 'Stayed',
    analyticsStatusHedging: 'Hedging',
    analyticsStatusSwitched: 'Switched',
    analyticsStatusNewVoter: 'New voter',
    analyticsStatusUndecided: 'Undecided',
    analyticsBaselineLabel: 'National average',
    analyticsTakeawayMoreLoyal: '{who} are more loyal to their old party than average.',
    analyticsTakeawayLessLoyal: '{who} are more volatile than average.',
    analyticsTakeawayAboutAverage: '{who} are about as loyal as average.',

    adminTitle: 'Voteball — Admin',
    adminHeading: 'Voteball — Admin',
    adminLabelUsername: 'Username:',
    adminLabelPassword: 'Password:',
    adminLogIn: 'Log in',
    adminTabPrevious: 'Previous Parties',
    adminTabUpcoming: 'Upcoming Parties',
    adminTabVotes: 'Votes',
    adminLogOut: 'Log out',
    adminHeadingPrevious: 'Previous Parties',
    adminHeadingUpcoming: 'Upcoming Parties',
    adminHeadingVotes: 'Votes',
    adminPlaceholderNameEn: 'English name',
    adminPlaceholderNameHe: 'Hebrew name',
    adminPlaceholderLogoUrl: 'Logo URL (optional)',
    adminAdd: 'Add',
    adminRename: 'Rename',
    adminReassign: 'Reassign votes…',
    adminDelete: 'Delete',
    adminSave: 'Save',
    adminReassignGo: 'Reassign',
    adminTabTeams: 'Teams',
    adminHeadingTeams: 'Teams',
    adminAddLeague: '+ Add league',
    adminAddClub: '+ Add club',
    adminDomesticLeagueNone: '— none —',
    adminAlsoInLeague: 'also in {league}',
    adminColId: 'ID',
    adminColCreated: 'Created',
    adminColTeams: 'Teams',
    adminJustLeagueSuffix: 'just the league',
    adminColPrevious: 'Previous vote',
    adminColUpcoming: 'Upcoming vote',
    adminDidNotVote: 'did not vote',
    adminUndecided: 'undecided',
    adminSomethingWrong: 'Something went wrong.',
    adminSomethingWrongRetry: 'Something went wrong — try again.',
    adminSessionExpired: 'Session expired — re-enter the secret.',
    adminIncorrectCredentials: 'Incorrect username or password.',
    adminConfirmDeleteParty: 'Delete "{name}"? This cannot be undone.',
    adminConfirmReassign: 'Reassign {count} votes from "{source}" to "{target}"? This cannot be undone.',
    adminConfirmDeleteVote: 'Delete vote #{id}? This cannot be undone.',
    adminAddToChampionsLeague: 'Add to UEFA Champions League',
    adminRemoveFromChampionsLeague: 'Remove from UEFA Champions League',
    adminUclAddDisabled: 'Already has a domestic league on file — edit via Rename instead.',
    adminUclRemoveDisabled: 'No domestic league on file — give it one via Rename first.',
  },
  he: {
    voteEyebrow: 'הצבעה חיה',
    voteHeroTitle: 'בחרו את הצד שלכם',
    voteIntro: 'אהדה לכדורגל מול הצבעה פוליטית — אנונימי, הצבעה אחת לדפדפן.',
    voteLegendLeague: 'ליגה וקבוצות',
    voteLeagueHint: 'בחרו עד 3 קבוצות בכל ליגה — או רק את הליגה אם אינכם עוקבים אחרי קבוצה ספציפית. אין הגבלה לליגה אחת.',
    voteClubPlaceholderOption: '— רק הליגה —',
    votePicksSummaryLabel: 'הבחירות שלכם עד כה:',
    votePicksSummaryEmpty: 'עדיין לא נבחרו קבוצות.',
    voteLegendPrevious: '2. הכנסת הנוכחית — למי הצבעתם?',
    voteDidNotVote: 'לא הצבעתי / לא זכאי',
    voteLegendUpcoming: 'הבחירות הקרובות — למי אתם שוקלים להצביע?',
    voteUpcomingHint: 'ניתן לבחור עד 3.',
    voteUndecided: 'עדיין לא החלטתי / מעדיף/ה לא לומר',
    voteReview: 'סקירת ההרכב שלכם',
    voteErrorLoadForm: 'לא הצלחנו לטעון את הטופס — נסו לרענן.',
    voteErrorRequiredFields: 'נא למלא את כל השדות הנדרשים.',
    voteErrorPickParty: 'בחרו לפחות מפלגה אחת שאתם שוקלים, או סמנו שעדיין לא החלטתם.',
    voteErrorSubmit: 'משהו השתבש בשליחת ההצבעה.',
    voteAlreadyVoted: 'כבר הצבעת מהדפדפן הזה — הצבעה אחת לכל מבקר, ולכן ההצבעה הזו לא נספרה. אפשר לראות את התוצאות בקישור למעלה.',
    voteReviewHeading: 'סקירת ההרכב שלכם',
    voteReviewTeams: 'קבוצות',
    voteReviewPrevious: 'הצבעה קודמת',
    voteReviewUpcoming: 'בחירות עתידיות',
    voteEdit: 'עריכה',
    voteConfirmSubmit: 'אישור ושליחה',

    navResults: 'תוצאות',
    navVote: 'להצבעה',

    resultsTitle: 'ווטבול — תוצאות',
    resultsHeading: 'ווטבול — תוצאות',
    resultsEyebrow: 'תוצאות חיות',
    resultsIntro: 'תוצאות אנונימיות ומצטברות מכל ההצבעות בווטבול עד כה.',
    resultsModeClubLeague: 'התחלה מקבוצה/ליגה',
    resultsModeParty: 'התחלה ממפלגה',
    resultsLabelLeague: 'ליגה:',
    resultsLabelClub: 'קבוצה (רשות):',
    resultsClubPlaceholderOption: '— כל הליגה —',
    resultsLabelPartyType: 'סוג מפלגה:',
    resultsPartyTypePrevious: 'הכנסת הנוכחית',
    resultsPartyTypeUpcoming: 'הבחירות הקרובות',
    resultsLabelParty: 'מפלגה:',
    resultsHeadingPrevious: 'התפלגות הצבעה בהכנסת הנוכחית',
    resultsHeadingUpcoming: 'התפלגות הבחירות הקרובות',
    resultsDidNotVote: 'לא הצביע/ה',
    resultsUndecided: 'לא החליט/ה',
    resultsLeagueWideSuffix: ' (כלל הליגה)',
    resultsErrorLoad: 'לא הצלחנו לטעון את התוצאות — נסו לרענן.',
    resultsNationalHeading: 'תוצאות ארציות',
    resultsExplorerHeading: 'חקרו את התוצאות',
    resultsNoData: 'אין עדיין הצבעות עבור בחירה זו.',
    resultsScopeNational: 'כלל הארץ',
    resultsYouBadge: 'אתם',
    resultsYourLineup: 'ההרכב שלכם',
    resultsScoreLabelTeam: 'קבוצה',
    resultsScoreLabelPrevious: 'בפעם הקודמת',
    resultsScoreLabelUpcoming: 'שוקלים',
    resultsFanLeanHeading: 'לאן נוטים אוהדי {who}',
    resultsFanLeanNoteClub: 'בחירות לבחירות הקרובות בקרב אוהדי {club}.',
    resultsFanLeanNoteLeague: 'בחירות לבחירות הקרובות בקרב עוקבי {league}.',
    resultsMigrationHeading: 'לאן פונה המחנה שלכם',
    resultsMigrationNote: 'בקרב מצביעי {scope} שבחרו ב{party} בפעם הקודמת, כך הם שוקלים להצביע עכשיו.',
    resultsMigrationNoteDidNotVote: 'סימנתם שלא הצבעתם בפעם הקודמת, כך שאין נתוני מעבר להציג.',

    analyticsHeading: 'פוליטיקת האוהדים',
    analyticsTabDiversity: 'גיוון',
    analyticsTabLean: 'נטייה פוליטית',
    analyticsTabSwitching: 'מעבר הצבעה',
    analyticsErrorLoad: 'לא הצלחנו לטעון — נסו לרענן.',
    analyticsSpotlight: 'בזרקור',
    analyticsFullRanking: 'דירוג מלא',
    analyticsIncludeWorldCup: 'כלול נבחרות מונדיאל',
    analyticsMostMixed: 'האוהדים המגוונים ביותר',
    analyticsMostOneSided: 'האוהדים החד-צדדיים ביותר',
    analyticsEffectiveParties: '{n} מפלגות אפקטיביות',
    analyticsTooFewVotes: 'אין עדיין מספיק הצבעות לציון גיוון משמעותי.',
    analyticsAxisLeft: 'שמאל',
    analyticsAxisRight: 'ימין',
    analyticsNoStatedPosition: 'אין עמדה מוצהרת',
    analyticsSecurityLabel: 'ביטחון:',
    analyticsReligiosityLabel: 'דת ומדינה:',
    analyticsBlocLabel: 'מחנה:',
    analyticsSectorLabel: 'מגזר:',
    analyticsBlocBibi: 'מחנה ביבי',
    analyticsBlocOpposition: 'אופוזיציה',
    analyticsBlocUnaligned: 'לא משויך',
    analyticsSectorSecular: 'חילוני',
    analyticsSectorTraditional: 'מסורתי',
    analyticsSectorReligiousZionist: 'ציוני דתי',
    analyticsSectorHaredi: 'חרדי',
    analyticsSectorArab: 'ערבי',
    analyticsSecurityDovish: 'יוני',
    analyticsSecurityHawkish: 'ניצי',
    analyticsReligiositySeparationist: 'הפרדתי',
    analyticsReligiosityClerical: 'קלריקלי',
    analyticsNational: 'כלל הארץ',
    analyticsPickClub: 'קפיצה למועדון:',
    analyticsScopeLabel: 'טווח:',
    analyticsStatusStayed: 'נשארו',
    analyticsStatusHedging: 'מהססים',
    analyticsStatusSwitched: 'עברו',
    analyticsStatusNewVoter: 'מצביע/ה חדש/ה',
    analyticsStatusUndecided: 'לא החליטו',
    analyticsBaselineLabel: 'ממוצע ארצי',
    analyticsTakeawayMoreLoyal: '{who} נאמנים יותר למפלגה הקודמת שלהם מהממוצע.',
    analyticsTakeawayLessLoyal: '{who} משתנים יותר מהממוצע.',
    analyticsTakeawayAboutAverage: '{who} נאמנים בערך כמו הממוצע.',

    adminTitle: 'ווטבול — ניהול',
    adminHeading: 'ווטבול — ניהול',
    adminLabelUsername: 'שם משתמש:',
    adminLabelPassword: 'סיסמה:',
    adminLogIn: 'התחברות',
    adminTabPrevious: 'מפלגות קודמות',
    adminTabUpcoming: 'מפלגות עתידיות',
    adminTabVotes: 'הצבעות',
    adminLogOut: 'התנתקות',
    adminHeadingPrevious: 'מפלגות קודמות',
    adminHeadingUpcoming: 'מפלגות עתידיות',
    adminHeadingVotes: 'הצבעות',
    adminPlaceholderNameEn: 'שם באנגלית',
    adminPlaceholderNameHe: 'שם בעברית',
    adminPlaceholderLogoUrl: 'כתובת URL ללוגו (רשות)',
    adminAdd: 'הוספה',
    adminRename: 'שינוי שם',
    adminReassign: 'העברת הצבעות…',
    adminDelete: 'מחיקה',
    adminSave: 'שמירה',
    adminReassignGo: 'העברה',
    adminTabTeams: 'קבוצות',
    adminHeadingTeams: 'קבוצות',
    adminAddLeague: '+ הוספת ליגה',
    adminAddClub: '+ הוספת קבוצה',
    adminDomesticLeagueNone: '— ללא —',
    adminAlsoInLeague: 'גם ב{league}',
    adminColId: 'מזהה',
    adminColCreated: 'נוצר',
    adminColTeams: 'קבוצות',
    adminJustLeagueSuffix: 'רק הליגה',
    adminColPrevious: 'הצבעה קודמת',
    adminColUpcoming: 'הצבעה עתידית',
    adminDidNotVote: 'לא הצביע/ה',
    adminUndecided: 'לא החליט/ה',
    adminSomethingWrong: 'משהו השתבש.',
    adminSomethingWrongRetry: 'משהו השתבש — נסו שוב.',
    adminSessionExpired: 'ההתחברות פגה — יש להזין את הסיסמה מחדש.',
    adminIncorrectCredentials: 'שם משתמש או סיסמה שגויים.',
    adminConfirmDeleteParty: 'למחוק את "{name}"? לא ניתן לבטל פעולה זו.',
    adminConfirmReassign: 'להעביר {count} הצבעות מ"{source}" ל"{target}"? לא ניתן לבטל פעולה זו.',
    adminConfirmDeleteVote: 'למחוק הצבעה מס\' {id}? לא ניתן לבטל פעולה זו.',
    adminAddToChampionsLeague: 'הוספה לליגת האלופות',
    adminRemoveFromChampionsLeague: 'הסרה מליגת האלופות',
    adminUclAddDisabled: 'כבר קיימת ליגה מקומית — לעריכה יש להשתמש בשינוי שם.',
    adminUclRemoveDisabled: 'אין ליגה מקומית רשומה — יש להוסיף אחת דרך שינוי שם קודם.',
  },
};

function detectInitialLang() {
  const stored = localStorage.getItem(LANG_STORAGE_KEY);
  if (stored === 'en' || stored === 'he') return stored;
  return (navigator.language || '').toLowerCase().startsWith('he') ? 'he' : 'en';
}

let currentLang = detectInitialLang();

function getLang() {
  return currentLang;
}

function applyDocumentDirection() {
  document.documentElement.lang = currentLang;
  document.documentElement.dir = currentLang === 'he' ? 'rtl' : 'ltr';
}

function t(key) {
  return DICTIONARY[currentLang][key] || key;
}

function localizedName(entity) {
  return currentLang === 'he' ? entity.name_he : entity.name_en;
}

function applyStaticText() {
  document.querySelectorAll('[data-i18n]').forEach(el => {
    el.textContent = t(el.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-placeholder]').forEach(el => {
    el.placeholder = t(el.dataset.i18nPlaceholder);
  });
}

function setLang(lang) {
  if (lang !== 'en' && lang !== 'he') return;
  currentLang = lang;
  localStorage.setItem(LANG_STORAGE_KEY, lang);
  applyDocumentDirection();
  applyStaticText();
  updateLangToggleButtons();
  document.dispatchEvent(new CustomEvent('voteball:langchange'));
}

function updateLangToggleButtons() {
  const toggle = document.getElementById('lang-toggle');
  if (!toggle) return;
  toggle.querySelectorAll('button[data-lang]').forEach(btn => {
    btn.setAttribute('aria-pressed', String(btn.dataset.lang === currentLang));
  });
}

function initLangToggle() {
  const toggle = document.getElementById('lang-toggle');
  if (!toggle) return;
  toggle.querySelectorAll('button[data-lang]').forEach(btn => {
    btn.addEventListener('click', () => setLang(btn.dataset.lang));
  });
  updateLangToggleButtons();
}

// Runs immediately, in <head>, before <body> is parsed — sets lang/dir before first paint.
applyDocumentDirection();

document.addEventListener('DOMContentLoaded', () => {
  applyStaticText();
  initLangToggle();
});
