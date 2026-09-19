import SwiftUI

struct QuickAction: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let category: String
    /// Prompt placed in the composer. If it ends with a colon the user is expected to complete it.
    let prompt: String
    let suggestions: [String]

    static let all: [QuickAction] = [
        QuickAction(id: "research", title: "Research", subtitle: "Deep-dive any topic", icon: "magnifyingglass", color: .blue, category: "Research",
                    prompt: "Research this topic and give me a sourced briefing: ",
                    suggestions: [
                        "Compare the top 3 project management tools for a 10-person startup and recommend one.",
                        "What are the latest developments in on-device AI models this month? Summarize with sources.",
                        "Find the best-reviewed noise-cancelling headphones under $300 and make a comparison table.",
                    ]),
        QuickAction(id: "schedule", title: "Plan my day", subtitle: "Calendar & reminders", icon: "calendar", color: .orange, category: "Schedule",
                    prompt: "Look at my calendar for today and tomorrow and help me plan: ",
                    suggestions: [
                        "Look at my calendar for the rest of the week and find three 1-hour slots for deep work. Book them.",
                        "Schedule a 30-minute dentist call on Thursday afternoon and remind me an hour before.",
                        "Give me a briefing of my day: events, and a suggested order to tackle things.",
                    ]),
        QuickAction(id: "documents", title: "Create a document", subtitle: "Reports, plans, PDFs", icon: "doc.richtext", color: .purple, category: "Documents",
                    prompt: "Create a PDF document: ",
                    suggestions: [
                        "Create a one-page PDF project proposal for launching a weekly newsletter at my company.",
                        "Write a meeting agenda for a 45-minute quarterly planning session and save it as a PDF.",
                        "Make a CSV of a 4-week beginner running plan with distance and pace per day.",
                    ]),
        QuickAction(id: "image", title: "Generate an image", subtitle: "Visuals & concepts", icon: "photo.on.rectangle.angled", color: .pink, category: "Images",
                    prompt: "Generate an image of ",
                    suggestions: [
                        "Generate a minimalist logo concept for a coffee brand called Northwind Roasters.",
                        "Generate a hero image for a blog post about remote work, warm and optimistic.",
                        "Generate a square Instagram visual announcing a 20% summer sale for a bookstore.",
                    ]),
        QuickAction(id: "health", title: "Health check-in", subtitle: "Activity, sleep, habits", icon: "heart.text.square", color: .red, category: "Health",
                    prompt: "Review my Apple Health data for the past week and ",
                    suggestions: [
                        "Review my Apple Health data for the past week and give me three practical improvements.",
                        "How has my sleep trended over the last two weeks? Suggest a wind-down routine.",
                        "Plan a 3-day beginner strength routine and add the sessions to my calendar this week.",
                    ]),
        QuickAction(id: "email", title: "Email assistant", subtitle: "Reply, follow up, reach out", icon: "envelope.open", color: .teal, category: "Email",
                    prompt: "Draft an email: ",
                    suggestions: [
                        "Draft a polite follow-up email to a client who hasn't replied to my proposal in a week.",
                        "Write a warm intro email connecting two people from my network for a coffee chat.",
                        "Reply to this email declining the meeting but proposing next week instead: (paste email)",
                    ]),
        QuickAction(id: "marketing", title: "Marketing", subtitle: "Campaigns & content", icon: "megaphone", color: .green, category: "Marketing",
                    prompt: "Help me with marketing: ",
                    suggestions: [
                        "Create a 2-week social media content calendar for a new productivity app launch, as a CSV.",
                        "Write 5 headline variations and a landing page hero section for an online cooking course.",
                        "Research my competitor's positioning at example.com and summarize gaps I can exploit.",
                    ]),
        QuickAction(id: "analyze", title: "Analyze a file or photo", subtitle: "Attach and ask", icon: "doc.viewfinder", color: .indigo, category: "Analysis",
                    prompt: "Analyze the attached file and ",
                    suggestions: [
                        "Summarize the attached PDF in 5 bullets and list any action items.",
                        "What's in this photo? Identify anything notable and suggest what to do next.",
                        "Extract every date, amount and name from the attached document into a CSV.",
                    ]),
    ]
}
