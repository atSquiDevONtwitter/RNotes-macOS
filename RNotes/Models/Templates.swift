//
//  Templates.swift
//  RNotes — Copyright (c) 2026 RTECH OSS. MIT License.
//
//  Note templates. Stored encrypted (name and body) in the `templates` table.
//  Placeholders are filled in when a note is created from a template:
//    {{date}}  {{time}}  {{weekday}}  {{cursor}} (where the caret starts)
//

import Foundation

struct NoteTemplate: Identifiable, Equatable {
    let id: String
    var name: String
    var body: String
    var sortOrder: Int
    let createdAt: Date
}

enum TemplateFiller {
    static let placeholders = ["{{date}}", "{{time}}", "{{weekday}}", "{{cursor}}"]

    /// Fills the placeholders. Returns the text and the caret position ({{cursor}}, UTF-16 offset).
    static func fill(_ template: String, date: Date = Date()) -> (text: String, caret: Int?) {
        let day = DateFormatter()
        day.dateStyle = .long
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let weekday = DateFormatter()
        weekday.setLocalizedDateFormatFromTemplate("EEEE")

        var text = template
            .replacingOccurrences(of: "{{date}}", with: day.string(from: date), options: .caseInsensitive)
            .replacingOccurrences(of: "{{time}}", with: time.string(from: date), options: .caseInsensitive)
            .replacingOccurrences(of: "{{weekday}}", with: weekday.string(from: date), options: .caseInsensitive)
        var caret: Int? = nil
        let marker = (text as NSString).range(of: "{{cursor}}", options: .caseInsensitive)
        if marker.location != NSNotFound {
            caret = marker.location
            text = (text as NSString).replacingCharacters(in: marker, with: "")
            // Only the first {{cursor}} counts; drop any others.
            text = text.replacingOccurrences(of: "{{cursor}}", with: "", options: .caseInsensitive)
        }
        return (text, caret)
    }

    /// Added the first time a vault is unlocked. They're ordinary templates: edit or delete them freely.
    static let builtIns: [(name: String, body: String)] = [
        ("Meeting", """
        # Meeting — {{date}}

        **Time:** {{time}}
        **Attendees:** {{cursor}}

        ## Agenda
        - 

        ## Notes


        ## Action items
        - [ ] 

        #meeting
        """),
        ("Journal", """
        # {{weekday}}, {{date}}

        ## How I'm feeling
        {{cursor}}

        ## What happened today


        ## Grateful for
        - 

        #journal
        """),
        ("To-Do", """
        # To-Do — {{date}}

        - [ ] {{cursor}}
        - [ ] 
        - [ ] 

        #todo
        """),
        ("Project", """
        # {{cursor}}

        **Started:** {{date}}
        **Status:** Planning

        ## Goal


        ## Tasks
        - [ ] 

        ## Notes


        ## Links


        #project
        """),
    ]
}
