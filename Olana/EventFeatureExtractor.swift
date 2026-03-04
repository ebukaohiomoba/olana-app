import Foundation

// MARK: - EventFeatureExtractor
class EventFeatureExtractor {
    
    // MARK: - Feature Extraction
    func extractFeatures(from text: String, dueDate: Date?) -> [String: Double] {
        var features: [String: Double] = [:]
        
        let lowercaseText = text.lowercased()
        
        // Basic text features
        features["text_length"] = Double(text.count)
        features["word_count"] = Double(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count)
        
        // Time-related features
        if let dueDate = dueDate {
            let hoursUntilDue = dueDate.timeIntervalSinceNow / 3600
            features["hours_until_due"] = hoursUntilDue
            features["is_overdue"] = hoursUntilDue < 0 ? 1.0 : 0.0
            features["due_within_24h"] = hoursUntilDue <= 24 ? 1.0 : 0.0
            features["due_within_week"] = hoursUntilDue <= 168 ? 1.0 : 0.0
        } else {
            features["hours_until_due"] = 1000.0 // Large value for no due date
            features["is_overdue"] = 0.0
            features["due_within_24h"] = 0.0
            features["due_within_week"] = 0.0
        }
        
        // Urgency keyword features
        let urgentKeywords = ["urgent", "emergency", "asap", "immediately", "critical", "help", "911", "now"]
        let importantKeywords = ["important", "deadline", "meeting", "appointment", "doctor", "interview", "exam"]
        let casualKeywords = ["maybe", "sometime", "eventually", "later", "consider", "think about"]
        
        features["urgent_keywords"] = Double(urgentKeywords.filter { lowercaseText.contains($0) }.count)
        features["important_keywords"] = Double(importantKeywords.filter { lowercaseText.contains($0) }.count)
        features["casual_keywords"] = Double(casualKeywords.filter { lowercaseText.contains($0) }.count)
        
        // Event type features
        features["is_medical"] = (lowercaseText.contains("doctor") || lowercaseText.contains("hospital") || lowercaseText.contains("medical") || lowercaseText.contains("dentist")) ? 1.0 : 0.0
        features["is_work"] = (lowercaseText.contains("work") || lowercaseText.contains("meeting") || lowercaseText.contains("deadline") || lowercaseText.contains("project")) ? 1.0 : 0.0
        features["is_social"] = (lowercaseText.contains("party") || lowercaseText.contains("dinner") || lowercaseText.contains("social") || lowercaseText.contains("hang out")) ? 1.0 : 0.0
        
        // Sentiment features (simplified)
        let positiveWords = ["good", "great", "excited", "fun", "happy", "looking forward"]
        let negativeWords = ["stressed", "worried", "anxious", "difficult", "problem", "issue"]
        
        features["positive_sentiment"] = Double(positiveWords.filter { lowercaseText.contains($0) }.count)
        features["negative_sentiment"] = Double(negativeWords.filter { lowercaseText.contains($0) }.count)
        
        // Punctuation features
        features["exclamation_marks"] = Double(text.filter { $0 == "!" }.count)
        features["question_marks"] = Double(text.filter { $0 == "?" }.count)
        features["caps_ratio"] = text.isEmpty ? 0.0 : Double(text.filter { $0.isUppercase }.count) / Double(text.count)
        
        return features
    }
}