const LANG_STORAGE_KEY = 'voteballLang';

const DICTIONARY = {
  en: {
    voteIntro: 'Football fandom vs. how you vote — anonymous, one vote per browser.',
    voteLegendLeague: '1. League',
    voteLabelLeague: 'League:',
    voteLabelClub: 'Club (optional, or leave blank if you just follow the league):',
    voteClubPlaceholderOption: '— just the league —',
    voteLegendPrevious: '2. Current Knesset — who did you vote for?',
    voteDidNotVote: "Didn't vote / not eligible",
    voteLegendUpcoming: '3. Upcoming election — who are you considering? (choose up to 3)',
    voteUndecided: 'Undecided / prefer not to say',
    voteSubmit: 'Submit vote',
    voteErrorLoadForm: "Couldn't load the form — try refreshing.",
    voteErrorRequiredFields: 'Please fill in all required fields.',
    voteErrorPickParty: "Pick at least one party you're considering, or mark yourself undecided.",
    voteErrorSubmit: 'Something went wrong submitting your vote.',

    resultsTitle: 'Voteball — Results',
    resultsHeading: 'Voteball — Results',
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
    adminColLeague: 'League',
    adminColClub: 'Club',
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
  },
  he: {
    voteIntro: 'אהדה לכדורגל מול הצבעה פוליטית — אנונימי, הצבעה אחת לדפדפן.',
    voteLegendLeague: '1. ליגה',
    voteLabelLeague: 'ליגה:',
    voteLabelClub: 'קבוצה (רשות, השאירו ריק אם אתם עוקבים רק אחרי הליגה):',
    voteClubPlaceholderOption: '— רק הליגה —',
    voteLegendPrevious: '2. הכנסת הנוכחית — למי הצבעתם?',
    voteDidNotVote: 'לא הצבעתי / לא זכאי',
    voteLegendUpcoming: '3. הבחירות הקרובות — למי אתם שוקלים להצביע? (עד 3)',
    voteUndecided: 'עדיין לא החלטתי / מעדיף/ה לא לומר',
    voteSubmit: 'שליחת הצבעה',
    voteErrorLoadForm: 'לא הצלחנו לטעון את הטופס — נסו לרענן.',
    voteErrorRequiredFields: 'נא למלא את כל השדות הנדרשים.',
    voteErrorPickParty: 'בחרו לפחות מפלגה אחת שאתם שוקלים, או סמנו שעדיין לא החלטתם.',
    voteErrorSubmit: 'משהו השתבש בשליחת ההצבעה.',

    resultsTitle: 'ווטבול — תוצאות',
    resultsHeading: 'ווטבול — תוצאות',
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
    adminColLeague: 'ליגה',
    adminColClub: 'קבוצה',
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
