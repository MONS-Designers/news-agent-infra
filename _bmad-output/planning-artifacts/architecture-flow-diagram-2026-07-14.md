# NewsAgent — תרשים זרימה ארכיטקטוני (לפגישה עם נעמי)

מקור: `_bmad-output/forge/daily-digest-agent/forged-idea.md`

## מה מציג התרשים

תרשים רצף (sequence diagram) יחיד, עם 5 "קופסאות" (boxes) שמייצגות swimlanes:
**משתמש / צד לקוח / צד שרת / מודל שפה (LLM) / מקורות חיצוניים**.

שני אזורים צבועים (rect) מפרידים בין:
- **שלב 1 — הרשמה** (חד-פעמי, ביוזמת המשתמש)
- **שלב 2 — ריצה יומית** (אוטומטי לגמרי — הסדרן מפעיל, לא המשתמש)
- **שלב 3 — קריאה** (יומי, פסיבי)

הנקודה הארכיטקטונית המרכזית: הלקוח (טופס הרשמה + תיבת מייל) הוא "רזה" — הוא לא שולף תוכן בעצמו אף פעם. כל השליפה מהאינטרנט הפתוח קורית בצד השרת, בשם המשתמש.

## הדיאגרמה

```mermaid
sequenceDiagram
    autonumber

    box rgb(219,234,254) משתמש
    actor User as משתמש (הקורא)
    end
    box rgb(254,243,199) צד לקוח (Thin Client)
    participant RegForm as טופס הרשמה
    participant Mailbox as תיבת מייל
    end
    box rgb(220,252,231) צד שרת
    participant Scheduler as סדרן יומי (Cron)
    participant Engine as מנוע גילוי ותוכן
    end
    box rgb(237,233,254) מודל שפה
    participant LLM as LLM
    end
    box rgb(243,244,246) מקורות חיצוניים
    participant Sources as מקורות תוכן (RSS / חיפוש)
    end

    Note over RegForm,Mailbox: לקוח "רזה" — רק שתי נקודות מגע: טופס הרשמה (חד-פעמי) ותיבת מייל (קריאה פסיבית).<br/>הלקוח לא שולף תוכן בעצמו — אף פעם.

    rect rgb(255,251,235)
        Note over User,Scheduler: שלב 1 — הרשמה (חד-פעמי, ביוזמת המשתמש)
        User->>RegForm: נרשם + מגדיר תחומי עניין
        RegForm->>Scheduler: שומר תחומי עניין למשתמש
        Scheduler-->>RegForm: אישור הרשמה
        RegForm-->>User: "נרשמת בהצלחה"
    end

    rect rgb(236,253,245)
        Note over Scheduler,Sources: שלב 2 — ריצה יומית, אוטומטית לגמרי.<br/>הסדרן מפעיל את הכל — לא המשתמש. כל השליפה מהאינטרנט קורית כאן, בצד השרת, בשמו.
        Scheduler->>Engine: טריגר יומי (cron)
        Engine->>Scheduler: בקשת תחומי עניין + רשימת ברירת מחדל
        Scheduler-->>Engine: תחומי עניין + מקורות ברירת מחדל
        Engine->>Sources: גילוי מקורות מתחומי העניין
        Sources-->>Engine: רשימת מקורות רלוונטיים
        Engine->>Sources: שליפת תוכן (RSS / חיפוש חופשי)
        Sources-->>Engine: תוכן גולמי (כתבות, פוסטים)
        Engine->>LLM: תרגום + סיכום + חלוקה לנושאים
        LLM-->>Engine: תוכן מתורגם, מתומצת, מסווג
        Engine->>Engine: רינדור הדיג'סט (HTML בעברית)
        Engine->>Scheduler: דיג'סט מוכן
        Scheduler->>Mailbox: שליחת אימייל יומי
    end

    rect rgb(239,246,255)
        Note over User,Mailbox: שלב 3 — קריאה (יומי, פסיבי — אין פעולת שליפה מצד המשתמש)
        Mailbox-->>User: התראה על מייל חדש
        User->>Mailbox: פותח וקורא את הדיג'סט
    end
```
