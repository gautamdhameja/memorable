import Foundation
import Accelerate

@MainActor
class PhotoCaptionService {
    private var categoryEmbeddings: [(category: String, embedding: [Float])] = []
    private var isReady = false
    private var usedCaptions: Set<String> = []

    struct Category: Sendable {
        let name: String
        let prompt: String
        let captions: [String]
    }

    nonisolated static let categories: [Category] = [
        Category(name: "people", prompt: "a photo of people together", captions: [
            "Who were you with that day?",
            "Looks like a good time together",
            "Some people just make everything better",
            "The best company you could ask for",
            "These are the ones who matter",
            "I bet there's a story behind this one",
            "Squad goals, honestly",
            "The kind of moment you can't plan",
            "Together is the best place to be",
            "This group has good energy",
            "Friendship looks good on everyone here",
            "You can feel the laughter in this photo",
        ]),
        Category(name: "selfie", prompt: "a selfie portrait photo", captions: [
            "Looking good that day",
            "This version of you was thriving",
            "Camera ready, always",
            "Some days you just feel it",
            "Main character energy right here",
            "You knew exactly what you were doing",
            "Confidence looks great on you",
            "This should've been your profile pic",
            "Self-love documented",
            "That angle though",
        ]),
        Category(name: "dog", prompt: "a photo of a dog", captions: [
            "Who's this good boy?",
            "That face could melt anyone",
            "Four legs and pure happiness",
            "Best friend energy right there",
            "Unconditional love in one photo",
            "They always know how to make you smile",
            "Whoever said money can't buy happiness never got a dog",
            "That tail was definitely wagging",
            "The goodest of good boys",
            "Those eyes are saying 'treat please'",
            "A face you could never say no to",
            "Every day is the best day when you're a dog",
        ]),
        Category(name: "cat", prompt: "a photo of a cat", captions: [
            "Living their best nine lives",
            "That look of pure independence",
            "Cats just know how to own a room",
            "Judging you, but with love",
            "Plotting world domination, probably",
            "Royalty doesn't need a crown",
            "The audacity. The grace. The cat.",
            "They chose you. Feel honored.",
            "Napping is an art form",
            "Zero interest in your opinion",
        ]),
        Category(name: "food", prompt: "a photo of food on a plate", captions: [
            "That looks absolutely delicious",
            "Wish you could taste this again?",
            "Some meals you never forget",
            "Food always tastes better in memories",
            "The camera eats first, obviously",
            "This deserved its own photoshoot",
            "Comfort food for the soul",
            "You can almost smell this photo",
            "Chef's kiss to whoever made this",
            "The most important meal of the day",
            "Calories don't count in memories",
        ]),
        Category(name: "beach", prompt: "a photo of a beach with ocean", captions: [
            "Can you still hear the waves?",
            "Sandy toes and salty air",
            "The ocean remembers you too",
            "Take me back to this shore",
            "Vitamin Sea at its finest",
            "Salt water fixes everything",
            "Somewhere between the sand and the stars",
            "The beach is always a good idea",
            "Toes in the sand, worries in the wind",
            "Blue water, clear mind",
        ]),
        Category(name: "mountain", prompt: "a photo of mountains", captions: [
            "That view was worth every step",
            "The mountains were calling",
            "How far up did you go?",
            "Breathtaking, literally",
            "On top of the world that day",
            "The higher you climb, the better the view",
            "Mountains don't care about your problems",
            "Fresh air and big dreams up there",
            "Earth's way of showing off",
            "Altitude changes everything",
        ]),
        Category(name: "sunset", prompt: "a photo of a sunset sky", captions: [
            "The sky really showed off that day",
            "Some sunsets stay with you forever",
            "Nature's daily masterpiece",
            "Pause. Breathe. Remember this.",
            "Golden hour never disappoints",
            "The sky was on fire that evening",
            "Free art show, courtesy of the sky",
            "This color palette though",
            "Even the clouds were impressed",
            "The perfect ending to that day",
        ]),
        Category(name: "city", prompt: "a photo of a city street with buildings", captions: [
            "Which city was this?",
            "Streets full of stories",
            "Urban adventures hit different",
            "Every corner had something new",
            "The city never sleeps, and neither did you",
            "Getting lost was the whole point",
            "Concrete jungle where dreams are made",
            "The best adventures start on a random street",
            "Architecture and memories",
            "This city changed you a little",
        ]),
        Category(name: "nature", prompt: "a photo of trees and greenery in nature", captions: [
            "Nature was showing off that day",
            "Sometimes you just need the green",
            "Fresh air and zero notifications",
            "The great outdoors at its finest",
            "Trees don't judge. They just stand there being awesome.",
            "Mother Nature's living room",
            "This is what peace looks like",
            "Touch grass? You went all in.",
            "Oxygen-rich memories",
            "Back when the Wi-Fi was weak but the connection was strong",
        ]),
        Category(name: "celebration", prompt: "a photo of a birthday party celebration", captions: [
            "What were you celebrating?",
            "Those were the good times",
            "Every celebration is worth remembering",
            "The joy in this photo is contagious",
            "Life's too short to skip the party",
            "This energy is unmatched",
            "You definitely earned this celebration",
            "The kind of night you talk about for years",
            "Cheers to that moment",
            "Cake, candles, and chaos probably",
        ]),
        Category(name: "travel", prompt: "a photo from traveling in a new place", captions: [
            "Where in the world was this?",
            "Exploring was always your thing",
            "New places, new memories",
            "Would you go back?",
            "Travel changes you in the best way",
            "Passport stamp worthy",
            "The world is big and you were out there seeing it",
            "Wanderlust at its peak",
            "Not all who wander are lost. Some are just you.",
            "Every trip tells a story",
        ]),
        Category(name: "night", prompt: "a photo taken at night with lights", captions: [
            "The night had its own magic",
            "After dark, things got interesting",
            "City lights or starlight?",
            "The night was young, and so were you",
            "Darkness makes the lights brighter",
            "Good things happen after midnight",
            "The night shift of memories",
            "Under the cover of stars",
        ]),
        Category(name: "snow", prompt: "a photo of snow in winter", captions: [
            "Was it as cold as it looks?",
            "Winter wonderland vibes",
            "The world looked so peaceful",
            "Snow makes everything look magical",
            "Cold hands, warm heart",
            "Jack Frost was showing off",
            "Footprints in fresh snow hit different",
            "Cozy memories from a frozen day",
        ]),
        Category(name: "flower", prompt: "a photo of flowers", captions: [
            "Nature's little art pieces",
            "Someone had an eye for beauty",
            "Flowers make everything better",
            "Stop and smell the memories",
            "Blooming where you were planted",
            "Petals and good vibes",
            "A little color goes a long way",
            "Even flowers are jealous of this shot",
        ]),
        Category(name: "car", prompt: "a photo of a car", captions: [
            "Where were you headed?",
            "The journey was the destination",
            "Road trip energy",
            "Windows down, music up",
            "Some roads you remember forever",
            "This ride had stories to tell",
            "Freedom on four wheels",
            "The open road was calling",
        ]),
        Category(name: "child", prompt: "a photo of a child playing", captions: [
            "They grow up so fast",
            "Pure joy, no filter needed",
            "Remember when everything was this simple?",
            "That laugh is everything",
            "Tiny humans, huge hearts",
            "This little one had the right idea",
            "Childhood is the best filter",
            "Growing up in real time",
            "The world through their eyes",
        ]),
        Category(name: "screenshot", prompt: "a screenshot of a phone screen", captions: [
            "Something worth saving",
            "You screenshotted this for a reason",
            "Digital memories count too",
            "The context is probably hilarious",
            "You were definitely sharing this with someone",
            "Some things need to be preserved",
        ]),
    ]

    /// Pre-encode all category prompts. Call once after TextEncoder is ready.
    func prepare(textEncoder: TextEncoder) async {
        let embeddings = await Task.detached {
            var embeddings: [(category: String, embedding: [Float])] = []
            for category in Self.categories {
                do {
                    let embedding = try textEncoder.encode(text: category.prompt)
                    embeddings.append((category: category.name, embedding: embedding))
                } catch {
                    #if DEBUG
                    logger.error("[PhotoCaption] Failed to encode category '\(category.name)': \(error.localizedDescription)")
                    #endif
                }
            }
            return embeddings
        }.value

        categoryEmbeddings = embeddings
        isReady = !embeddings.isEmpty

        #if DEBUG
        let count = embeddings.count
        logger.info("[PhotoCaption] Prepared \(count) category embeddings")
        #endif
    }

    /// Given a photo's embedding (Float16 from DB), find the best category and return a caption.
    /// Tracks used captions to avoid repeats.
    func caption(for photoEmbedding: [Float16]) -> String? {
        guard isReady else { return nil }

        let dim = photoEmbedding.count
        guard dim > 0 else { return nil }

        var photoFloat = [Float](repeating: 0, count: dim)
        for i in 0..<dim { photoFloat[i] = Float(photoEmbedding[i]) }

        var bestScore: Float = -1
        var bestCategory: String?

        for (category, catEmbedding) in categoryEmbeddings {
            guard catEmbedding.count == dim else { continue }
            var dot: Float = 0
            vDSP_dotpr(photoFloat, 1, catEmbedding, 1, &dot, vDSP_Length(dim))
            if dot > bestScore {
                bestScore = dot
                bestCategory = category
            }
        }

        guard let matched = bestCategory,
              let category = Self.categories.first(where: { $0.name == matched }) else { return nil }

        // Pick a caption we haven't used recently
        let available = category.captions.filter { !usedCaptions.contains($0) }
        let caption: String
        if let fresh = available.randomElement() {
            caption = fresh
        } else {
            // All used. Reset and pick any. Fall back to a generic placeholder
            // rather than "" if the category somehow has no captions at all,
            // so callers never have to handle an empty string.
            usedCaptions.removeAll()
            caption = category.captions.randomElement() ?? "Memory"
        }

        usedCaptions.insert(caption)
        // Keep the used set from growing unbounded
        if usedCaptions.count > 50 { usedCaptions.removeAll() }

        return caption
    }
}
